% =============================================================================
% OFDM TRANSMITTER
% Shared parameters (OFDMParams, modulation, RF, message) live in config.m.
% Edit config.m to keep TX and RX in sync.
% =============================================================================

% Load shared parameters
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

% Repeat the data in a buffer for PLUTO radio to make sure there are less
% underruns. The receiver decodes only one frame from where the first
% synchroization signal is received
txOutSize = length(txOut);
if contains(radioDevice,'PLUTO') && txOutSize < 48000
    frameCnt = ceil(48000/txOutSize);
    txWaveform = zeros(txOutSize*frameCnt,1);
    for i = 1:frameCnt
        txWaveform(txOutSize*(i-1)+1:i*txOutSize) = txOut;
    end
else
    txWaveform = txOut;
end


if dataParams.enableScopes
    spectrumAnalyze(txOut);
end




%After the signal is genearted, we need to transmit it over the radio:

for frameNum = 1:sysParam.numFrames+1
    underrun = radio(txWaveform);
    tunderrun = tunderrun + underrun;  %li Total underruns


    % ONLY update the display every 100 frames to prevent lag
    if mod(frameNum, 100) == 0
        % Get current time down to milliseconds
        currTime = datetime('now', 'Format', 'HH:mm:ss.SSS');
        
        % Calculate progress percentage
        progress = (frameNum / sysParam.numFrames) * 100;
        
        % Print the status line
        fprintf('Time: %s | Frame: %d/%d (%.1f%%) | Total Underruns: %d\n', ...
            string(currTime), frameNum, sysParam.numFrames, progress, tunderrun);
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