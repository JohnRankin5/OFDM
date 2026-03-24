% =============================================================================
% OFDM TRANSMITTER
% Shared parameters (OFDMParams, modulation, RF, message) live in config.m.
% Edit config.m to keep TX and RX in sync.
% =============================================================================

% Load shared parameters
close all; clear; clc;
run(fullfile(fileparts(mfilename('fullpath')), '..', 'config.m'));

% TX-specific parameters
dataParams.numFrames    = txNumFrames; % Set in config.m → txNumFrames
dataParams.enableScopes = true;  % Show spectrum analyzer scope
dataParams.verbosity    = false; % Verbose debug output (true = per-frame logs)


%Device type and center frequnecy:
radioDevice = "PLUTO";  
dev = sdrdev('Pluto');

gain = -10;





%Make sure the right device is selected and the correct parameter are set
%on the pluto
[sysParam,txParam,trBlk] = helperOFDMSetParamsSDR(OFDMParams,dataParams);
sampleRate               = sysParam.scs*sysParam.FFTLen;                % Sample rate of signal
% ofdmTx                   = helperGetRadioParams(sysParam,radioDevice,sampleRate,centerFrequency,gain);

% 
% ofdmTx                   = sdrtx('Pluto', ...
%     'RadioID', 'usb:0', ...
%     'CenterFrequency', centerFrequency, ...
%     'BasebandSampleRate', sampleRate, ...
%     'Gain', gain, ...
%     'ShowAdvancedProperties', true);
% 




% 1. Define the Serial Number you want to use for the Transmitter
targetSerialTx = '1044739a470b000ae9ff21009ad37f0427'; 

% 2. Find all connected Plutos
radios = findPlutoRadio;
txRadioID = '';

% 3. Loop through them to find the match
for i = 1:length(radios)
    if strcmp(radios(i).SerialNum, targetSerialTx)
        txRadioID = radios(i).RadioID; % Grab the correct 'usb:X' ID
        break;
    end
end

% 4. Error check: Did we find it?
if isempty(txRadioID)
    error('Transmitter Pluto not found! Check connection.');
end

% 5. Initialize the Transmitter using the found ID
ofdmTx = sdrtx('Pluto', ...
    'RadioID', txRadioID, ... 
    'CenterFrequency', centerFrequency, ...
    'BasebandSampleRate', sampleRate, ...
    'Gain', gain, ...
    'ShowAdvancedProperties', true);

disp(['Transmitter successfully connected to: ' txRadioID]);




% Get the radio transmitter and spectrum analyzer system object system object for the user to visualize the transmitted waveform.
% [radio,spectrumAnalyze] = helperGetRadioTxObj(ofdmTx);

% -------------------------------------------------------------------
% Replace missing helperGetRadioTxObj functionality
% -------------------------------------------------------------------

% Radio System object (sdrtx)
radio = ofdmTx;

% Spectrum analyzer for visualizing the transmit waveform
spectrumAnalyze = spectrumAnalyzer( ...
    'SampleRate', sampleRate, ...
    'SpectrumType', 'Power', ...
    'PlotAsTwoSidedSpectrum', true , ...
    'ChannelNames', {'OFDM Tx Signal'}, ...
    'ShowLegend', false);
 

% Initialize transmitter
txObj = helperOFDMTxInit(sysParam);



tunderrun = 0; % Initialize count for underruns

% A known payload is generated in the function helperOFDMSetParams with
% respect to the calculated trBlkSize
% Store data bits for BER calculations
txParam.txDataBits = trBlk;
[txOut,txGrid,txDiagnostics] = helperOFDMTx(txParam,sysParam,txObj);

% --- Save TX reference data for ML training ---
% tx_reference.mat is the ground-truth label file paired with RX captures.
%   txGrid  : clean transmitted resource grid (numSubCar x numSymPerFrame complex)
%             This is the ideal, noise-free version of RawGrid from the RX.
%   trBlk   : known transmitted bit sequence (1 x trBlkSize)
%             This is the ground-truth label for RawBits from the RX.
%   sysParam: system parameters used for this transmission
txRefDir  = fullfile(fileparts(mfilename('fullpath')), '..', 'R', 'captures');
if ~exist(txRefDir, 'dir'), mkdir(txRefDir); end
txRefTimestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
txRefFile = fullfile(txRefDir, sprintf('tx_reference_%s.mat', txRefTimestamp));
save(txRefFile, 'txGrid', 'trBlk', 'sysParam');
% Also save a fixed-name version for quick pairing with OFDM_Demodulated_Data.mat
save(fullfile(txRefDir, '..', 'tx_reference.mat'), 'txGrid', 'trBlk', 'sysParam');
fprintf('TX reference saved: %s\n', txRefFile);

% Display the grid if verbosity flag is enabled
if dataParams.verbosity
    helperOFDMPlotResourceGrid(txGrid,sysParam);
end

% Repeat the data in a buffer for PLUTO radio to make sure there are NO
% underruns. OS thread latency causes micro-gaps if we loop too tightly.
% We dynamically size the TX burst to perfectly encompass the entire desired
% RX capture period (plus a small warmup margin), eliminating all loop gaps.
txOutSize = length(txOut);
if contains(radioDevice,'PLUTO')
    % rxNumFrames + 40 margin frames to account for connection setup
    requiredFrames = dataParams.numFrames + 40;
    
    % Cap at 4M samples (~1000 frames) for TX streaming mode.
    % NOTE: The original 160k limit was for RX burst mode — the TX uses continuous
    % streaming which has a much higher safe buffer ceiling on Pluto SDR.
    % A 40-frame (160k) buffer caused a USB gap every 40 frames (~every 0.16s),
    % making the GAP FIX trigger nearly continuously and consuming all recovery budget.
    % At 1000 frames (4M samples), gaps appear only ~10 times per 10k-frame session.
    if (requiredFrames * txOutSize) > 4000000
        requiredFrames = floor(4000000 / txOutSize);
    end
    
    txWaveform = zeros(txOutSize * requiredFrames, 1);
    for i = 1:requiredFrames
        txWaveform(txOutSize*(i-1)+1 : i*txOutSize) = txOut;
    end
else
    txWaveform = txOut;
end


if dataParams.enableScopes
    spectrumAnalyze(txOut);
end




% Normalize the absolute root directory without using relative '..' strings
rootDir = fileparts(fileparts(mfilename('fullpath')));
flagFile = fullfile(rootDir, 'rx_running.flag');

if txWaitForRX
    % --- MODE: run until RX finishes (flag file controlled) ---
    fprintf('txWaitForRX=true: TX waiting for RX to initialize...\n');
    while ~exist(flagFile, 'file')
        pause(0.5);
    end
    fprintf('RX Flag detected! Sparing 2.0 seconds for SDR boot sequence...\n');
    pause(2.0);
    fprintf('TX is now continuously broadcasting signal.\n');
    
    frameNum = 0;
    missingFlagCount = 0; % Ensure flag is really gone, not just temporarily locked
    fprintf('txWaitForRX=true: TX broadcasts until RX finishes.\n');
    fprintf('Safety cap: %d frames. Start OFDMR_Working.m now.\n', txNumFrames);

    while frameNum < txNumFrames
        frameNum  = frameNum + 1;
        underrun  = radio(txWaveform);
        tunderrun = tunderrun + underrun;

        % Robust flag check: require flag to be missing multiple times consecutively
        if frameNum > 10
            if ~exist(flagFile, 'file')
                missingFlagCount = missingFlagCount + 1;
                if missingFlagCount >= 5
                    fprintf('\nRX finished. TX stopping after %d physical frames sent.\n', frameNum * requiredFrames);
                    break;
                end
            else
                missingFlagCount = 0; % reset if flag reappears
            end
        end

        if mod(frameNum, 10) == 0
            rxActive = exist(flagFile, 'file');
            physicalFramesSent = frameNum * requiredFrames;
            fprintf('Time: %s | Physical OFDM Frames Sent: %d | Underruns: %d | RX active: %s\n', ...
                datestr(now,'HH:MM:SS'), physicalFramesSent, tunderrun, mat2str(logical(rxActive)));
        end
    end

else
    % --- MODE: fixed frame count ---
    fprintf('txWaitForRX=false: TX broadcasts for %d frames.\n', txNumFrames);
    for frameNum = 1:txNumFrames
        underrun  = radio(txWaveform);
        tunderrun = tunderrun + underrun;

        if mod(frameNum, 100) == 0
            progress = (frameNum / txNumFrames) * 100;
            fprintf('Time: %s | Frame: %d/%d (%.1f%%) | Underruns: %d\n', ...
                datestr(now,'HH:MM:SS'), frameNum, txNumFrames, progress, tunderrun);
        end
    end
end





%The forever loop version:
% while true
%     underrun = radio(txWaveform);
%     % We don't really need to count underruns for an infinite loop, 
%     % but you can keep the line if you want:
%     % tunderrun = tunderrun + underrun; 
% end


% Clean up the radio System object



%Release the radio:
release(radio);