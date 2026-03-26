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

% Make unique TX bits and waveforms for ALL requested frames (e.g. 10,000)
numSeq = dataParams.numFrames;
allTxBits = cell(1, numSeq);
allTxGrids = cell(1, numSeq);

txOutSize = sysParam.txWaveformSize;
txWaveform = zeros(txOutSize * numSeq, 1);

fprintf('Generating %d unique TX frames (this may take a moment)...\n', numSeq);
for seqIdx = 1:numSeq
    % Random stream per frame — maximum diversity for ML training
    txParam.txDataBits = randi([0 1], sysParam.trBlkSize, 1);
    
    % Embed 6-bit wrapped sequence ID so RX can identify each frame in the header
    txParam.frameSeqNum = mod(seqIdx - 1, 64);
    
    [txOut,txGrid,~] = helperOFDMTx(txParam,sysParam,txObj);
    
    allTxBits{seqIdx}  = txParam.txDataBits(1:sysParam.trBlkSize);
    allTxGrids{seqIdx} = txGrid;
    
    % Insert directly into the massive TX array
    txWaveform( txOutSize*(seqIdx-1)+1 : seqIdx*txOutSize ) = txOut;
    
    if mod(seqIdx, 1000) == 0
        fprintf('Generated %d/%d frames...\n', seqIdx, numSeq);
    end
end

% --- Save TX reference data for ML training ---
% Sequence maps frameSeqNum to exact grid and bits
txRefDir  = fullfile(fileparts(mfilename('fullpath')), '..', 'R', 'captures');
if ~exist(txRefDir, 'dir'), mkdir(txRefDir); end
txRefTimestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
txRefFile = fullfile(txRefDir, sprintf('tx_reference_%s.mat', txRefTimestamp));
save(txRefFile, 'allTxBits', 'allTxGrids', 'sysParam', '-v7.3');

% Overwrite the base reference file (delete first — HDF5 can't cleanly overwrite)
baseRefFile = fullfile(txRefDir, '..', 'tx_reference.mat');
if exist(baseRefFile, 'file'), delete(baseRefFile); end
save(baseRefFile, 'allTxBits', 'allTxGrids', 'sysParam', '-v7.3');
fprintf('TX reference saved: %d frames → %s\n', numSeq, baseRefFile);

% Optional: Instead of spectrum analyzing the entire massive array, just do a snippet
if dataParams.enableScopes
    spectrumAnalyze(txWaveform(1:txOutSize*10));
end


if dataParams.enableScopes
    spectrumAnalyze(txOut);
end

% The PlutoSDR driver has a hard limit of 16.7M samples per continuous buffer push,
% AND it will violently crash if the input array size changes between calls.
if length(txWaveform) <= 10000000
    % Array is small enough to fit completely inside the driver, no chunking needed!
    chunkSamples = length(txWaveform);
    numChunks = 1;
else
    % Array is overwhelmingly large, we mathematically chunk and securely pad it!
    maxFramesPerChunk = floor(10000000 / txOutSize);
    chunkSamples = maxFramesPerChunk * txOutSize;
    numChunks = ceil(length(txWaveform) / chunkSamples);
    
    paddedLength = numChunks * chunkSamples;
    if paddedLength > length(txWaveform)
        padSamples = paddedLength - length(txWaveform);
        % Robust mathematical wrap-around that works even if pad > original
        numReps = ceil(padSamples / length(txWaveform));
        circularPad = repmat(txWaveform, numReps, 1);
        txWaveform = [txWaveform; circularPad(1:padSamples)];
    end
end

% Normalize the absolute root directory without using relative '..' strings
rootDir = fileparts(fileparts(mfilename('fullpath')));
flagFile = fullfile(rootDir, 'rx_running.flag');

% Clean up any stale flag from a previous crashed session at TX startup
if exist(flagFile, 'file'), delete(flagFile); end

if txWaitForRX
    % --- MODE: run until RX finishes (flag file controlled) ---
    fprintf('txWaitForRX=true: TX waiting for RX to initialize...\n');
    while ~exist(flagFile, 'file')
        pause(0.5);
    end
    fprintf('RX Flag detected! Sparing 10.0 seconds for SDR boot sequence...\n');
    pause(15.0);
    fprintf('TX is now continuously broadcasting signal.\n');
    
    frameNum = 0;
    missingFlagCount = 0; % Ensure flag is really gone, not just temporarily locked
    fprintf('txWaitForRX=true: TX broadcasts until RX finishes.\n');
    fprintf('Safety cap: %d frames. Start OFDMR_Working.m now.\n', txNumFrames);

    while frameNum < txNumFrames
        frameNum  = frameNum + 1;
        
        % Feed the SDR in chunks to bypass memory limits
        for cIdx = 1:numChunks
            idxStart = (cIdx-1)*chunkSamples + 1;
            idxEnd   = min(cIdx*chunkSamples, length(txWaveform));
            underrun = radio(txWaveform(idxStart:idxEnd));
            tunderrun = tunderrun + underrun;
        end

        % Robust flag check: require flag to be missing multiple times consecutively
        if frameNum > 10
            if ~exist(flagFile, 'file')
                missingFlagCount = missingFlagCount + 1;
                if missingFlagCount >= 5
                    fprintf('\nRX finished. TX stopping after %d TX Array loops.\n', frameNum);
                    break;
                end
            else
                missingFlagCount = 0; % reset if flag reappears
            end
        end

        if mod(frameNum, 5) == 0
            rxActive = exist(flagFile, 'file');
            fprintf('Time: %s | TX Array Loops Sent: %d | Underruns: %d | RX active: %s\n', ...
                datestr(now,'HH:MM:SS'), frameNum, tunderrun, mat2str(logical(rxActive)));
        end
    end

else
    % --- MODE: fixed frame count ---
    fprintf('txWaitForRX=false: TX broadcasts for %d Array loops.\n', txNumFrames);
    
    for frameNum = 1:txNumFrames
        for cIdx = 1:numChunks
            idxStart = (cIdx-1)*chunkSamples + 1;
            idxEnd   = min(cIdx*chunkSamples, length(txWaveform));
            underrun = radio(txWaveform(idxStart:idxEnd));
            tunderrun = tunderrun + underrun;
        end

        if mod(frameNum, 100) == 0
            progress = (frameNum / txNumFrames) * 100;
            fprintf('Time: %s | Loop: %d/%d (%.1f%%) | Underruns: %d\n', ...
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