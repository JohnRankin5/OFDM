% =============================================================================
% OFDM RECEIVER
% Shared parameters (OFDMParams, modulation, RF, message) live in config.m.
% Edit config.m to keep TX and RX in sync.
% =============================================================================

% Reset persistent state from any previous run.
close all; clear; clc;

% Load shared parameters
run(fullfile(fileparts(mfilename('fullpath')), '..', 'config.m'));

% RX-specific parameters
dataParams.numFrames    = rxNumFrames; % Set in config.m → rxNumFrames
radioDevice = 'PLUTO';           % SDR device type
gain        = 10;                % Receiver gain (dB) — increase if signal is weak

%Make sure the right device is selected and the correct parameter are set
[sysParam,txParam,transportBlk] = helperOFDMSetParamsSDR(OFDMParams,dataParams);
sampleRate                       = sysParam.scs*sysParam.FFTLen;                % Sample rate of signal

if loopbackMode
    % --- LOOPBACK MODE: generate TX waveform internally, no hardware needed ---
    fprintf('=== LOOPBACK MODE === (loopbackMode=true in config.m)\n');
    fprintf('SNR = %.0f dB | No PlutoSDR required.\n', loopbackSNR_dB);
    % Add TX folder to path so helperOFDMTxInit / helperOFDMTx are accessible
    addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'T'));
    txObjLB = helperOFDMTxInit(sysParam);  % takes sysParam (not txParam)
    txParam.txDataBits = transportBlk;
    [loopbackWaveform, txGridLB, ~] = helperOFDMTx(txParam, sysParam, txObjLB);
    % Repeat to fill the correct block size
    loopbackWaveform = repmat(loopbackWaveform, 1, 1); % Just pass 3200 samples
    radioLB = @() deal(loopbackWaveform, 0, false);
    radio = radioLB;
    spectrumAnalyze = @(x) [];
    constDiag       = @(h,d) [];
    fprintf('Loopback waveform ready (%d samples).\n', length(loopbackWaveform));

    % Save tx_reference.mat so plot_ofdm_grid.m can load TX vs RX comparison
    txGrid   = txGridLB;
    txRefDir = fullfile(fileparts(mfilename('fullpath')), 'captures');
    if ~exist(txRefDir, 'dir'), mkdir(txRefDir); end
    save(fullfile(fileparts(mfilename('fullpath')), 'tx_reference.mat'), 'txGrid', 'transportBlk', 'sysParam');
    txRefTS  = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
    save(fullfile(txRefDir, sprintf('tx_reference_%s.mat', txRefTS)), 'txGrid', 'transportBlk', 'sysParam');
    fprintf('TX reference saved: R/tx_reference.mat\n');
else
    % --- HARDWARE MODE: connect to PlutoSDR ---
    ofdmRx = helperGetRadioParams(sysParam,radioDevice,sampleRate,centerFrequency,gain);
    [radio,spectrumAnalyze,constDiag] = helperGetRadioRxObj(ofdmRx);
    
    % 1. Define the Serial Number for the Receiver
    targetSerialRx = '1044739a470b0002ffff270027b37feec0';
    % 2. Find all connected Plutos
    radios = findPlutoRadio;
    rxRadioID = '';
    % 3. Loop through them to find the match
    for i = 1:length(radios)
        if strcmp(radios(i).SerialNum, targetSerialRx)
            rxRadioID = radios(i).RadioID;
            break;
        end
    end
    % 4. Error check
    if isempty(rxRadioID)
        error('Receiver Pluto not found! Check connection.');
    end
    disp(['Receiver successfully connected to: ' rxRadioID]);
    
    % 5. Initialize the Receiver using the found ID
    ofdmRx = sdrrx('Pluto', ...
        'RadioID', rxRadioID, ...
        'CenterFrequency', centerFrequency, ...
        'BasebandSampleRate', sampleRate, ...
        'SamplesPerFrame', 32768, ...
        'OutputDataType', 'double', ...
        'GainSource', 'AGC Fast Attack');
end

% Clear variables
clear helperOFDMRx helperOFDMRxFrontEnd helperOFDMRxSearch helperOFDMFrequencyOffset;
errorRate = comm.ErrorRate();
toverflow = 0; 
rxObj = helperOFDMRxInit(sysParam);
BER = zeros(1,dataParams.numFrames);

% Status tracking variables for the dashboard
framesSynced = 0;
lastMessage  = 'Waiting for data...';  % char array (not string object)
currentBER   = 0;

% --- Setup versioned captures directory ---
captureDir = fullfile(fileparts(mfilename('fullpath')), 'captures');
if ~exist(captureDir, 'dir')
    mkdir(captureDir);
    fprintf('Created captures directory: %s\n', captureDir);
end
captureTimestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
captureFilename  = fullfile(captureDir, sprintf('capture_%s.mat', captureTimestamp));

% Struct to save demodulated information per frame:
%   Frame         - sequential frame index
%   BER           - per-frame bit error rate (0.0 = perfect)
%   Message       - decoded ASCII payload
%   TxBits        - known transmitted bits (ground truth for ML training)
%   RawBits       - received decoded bits (compare against TxBits)
%   RawGrid       - complex time-freq resource grid (pre-equalization, ML input)
%   SNR_dB        - estimated SNR from post-equalization EVM
%   Timestamp     - wall-clock time this frame was decoded
%   headerCRCPass - true if header CRC check passed
%   dataCRCPass   - true if data CRC check passed
demodulatedData = struct('Frame',{}, 'BER',{}, 'Message',{}, ...
    'TxBits',{}, 'RawBits',{}, 'RawGrid',{}, ...
    'SNR_dB',{}, 'Timestamp',{}, 'headerCRCPass',{}, 'dataCRCPass',{});
dataIdx = 1;

% --- Flag file: signal TX to keep transmitting while RX is running ---
if txWaitForRX
    % Normalize the root path natively without using relative strings
    rootDir = fileparts(fileparts(mfilename('fullpath')));
    flagFile = fullfile(rootDir, 'rx_running.flag');
    fid = fopen(flagFile, 'w'); fclose(fid);
    fprintf('Flag created: TX will broadcast until this RX session ends.\n');
end

fprintf('\nWaiting for signal (receiver will run indefinitely until signal is found)...\n');

% --- TWO-STAGE ARCHITECTURE ---
% Stage 1: Fast RAM Capture (Bypass USB bottlenecks)
% Stage 2: Offline Decode & Auto-Recovery (Bypass hardware loop gaps)

framesToCapture = dataParams.numFrames;
% Pre-allocate an additional 150 frames to absorb hardware phase locks and gap re-locks
allocatedFrames = framesToCapture + 150;
totalSamples = allocatedFrames * sysParam.txWaveformSize;

% Clear previous run's heavyweight variables so MATLAB doesn't hold
% two copies of the array simultaneously → prevents OOM on re-run.
clear rawIQ demodulatedData;
% Use single precision: Pluto SDR is 12-bit ADC so single (8 bytes/sample)
% retains full hardware fidelity at exactly HALF the RAM cost of double (16 bytes).
% 10,150 frames × 4,000 samples × 8 bytes = ~325 MB instead of 650 MB.
rawIQ = complex(zeros(totalSamples, 1, 'single'));
toverflow = 0;
idx = 1;

% --- SDR AGC WARMUP: drain a few chunks to let the Pluto's analog gain stabilize ---
% Without this, the auto-gain circuitry produces noisy transitional samples
% at startup that look like garbage to the sync correlator, delaying detection by seconds.
fprintf('SDR warming up (draining AGC noise)...\n');
for warmup = 1:8
    if loopbackMode
        radio(); % drain
    else
        radio(); % drain
    end
end
fprintf('SDR ready. Searching for signal...\n');

% --- WAIT FOR SIGNAL LOOP ---
prevChunk = [];
while true
    if loopbackMode
        [rxChunk, overflow, ~] = radio();
        noisePwr = 10^(-loopbackSNR_dB/10) * mean(abs(rxChunk).^2);
        rxChunk = rxChunk + sqrt(noisePwr/2)*(randn(size(rxChunk))+1j*randn(size(rxChunk)));
        overflow = false;
    else
        [rxChunk, ~, overflow] = radio();
    end
    toverflow = toverflow + overflow;
    
    % If we have a previous chunk, overlap them to guarantee we don't mathematically split
    % the Sync symbol across the boundary of the chunks, accelerating the trigger to instant!
    if isempty(prevChunk)
        searchChunk = rxChunk;
    else
        searchChunk = [prevChunk; rxChunk];
    end
    prevChunk = rxChunk;
    
    % Very fast heuristic: If we find a sync symbol, instantly trigger the massive RAM dump!
    [~, ta, ~] = helperOFDMRxSearch(searchChunk, sysParam);
    if cellfun(@(x) ~isempty(x), {ta}) || ~isempty(ta) % Robust check for any non-empty ta
        fprintf('Signal detected! Instantly triggering High-Speed RAM Capture...\n');
        
        % We MUST keep the trigger chunk because it contains our first frame!
        len = length(searchChunk);
        rawIQ(idx : idx+len-1) = searchChunk;
        idx = idx + len;
        break;
    end
end

fprintf('[STAGE 1] Capturing %.1f Million samples straight to RAM...\n', totalSamples/1e6);

% Grab the rest of the data as fast as physically possible
while idx <= totalSamples
    if loopbackMode
        [rxChunk, overflow, ~] = radio();
        noisePwr = 10^(-loopbackSNR_dB/10) * mean(abs(rxChunk).^2);
        rxChunk = rxChunk + sqrt(noisePwr/2)*(randn(size(rxChunk))+1j*randn(size(rxChunk)));
        overflow = false;
    else
        [rxChunk, ~, overflow] = radio();
    end
    toverflow = toverflow + overflow;
    
    len = length(rxChunk);
    if (idx + len - 1) <= totalSamples
        rawIQ(idx : idx+len-1) = rxChunk;
    end
    idx = idx + len;
end
fprintf('Capture Complete! (Overruns: %d)\n\n', toverflow);
if ~loopbackMode
    release(radio); % Free the hardware
end

% --- All IQ data is in RAM. TX is no longer needed. Shut it down NOW. ---
if txWaitForRX && exist(flagFile, 'file')
    delete(flagFile);
    fprintf('Stage 1 complete: Flag removed. TX will stop after its current frame.\n');
end

fprintf('[STAGE 2] Offline Decoding %d frames...\n', framesToCapture);
% Print the Fixed-Width Header
fprintf('======================================================================================\n');
fprintf('| Progress |   Status    |    BER    | Underruns | Last Message                     \n');
fprintf('|----------|-------------|-----------|-----------|----------------------------------\n');

framesCaptured = 0;
signalDetected = false;
chunkIdx = 1;
consecutiveFails = 0;
    
while framesCaptured < framesToCapture && (chunkIdx + sysParam.txWaveformSize - 1) <= totalSamples
    sysParam.frameNum = framesCaptured + 1;
    
    % Extract the next frame-sized chunk from the RAM array.
    rxWaveform = rawIQ(chunkIdx : chunkIdx + sysParam.txWaveformSize - 1);
    chunkIdx = chunkIdx + sysParam.txWaveformSize;
    
    rxIn = helperOFDMRxFrontEnd(rxWaveform,sysParam,rxObj);
    [rxDataBits,isConnected,toff,rxDiagnostics] = helperOFDMRx(rxIn,sysParam,rxObj);
    if isempty(toff)
        % Failed to find sync in this chunk
    elseif toff > 0 && ~isConnected
        % Found sync, but not camped yet
    end
    sysParam.timingAdvance = toff;
    
    if isConnected && ~signalDetected
        signalDetected = true;
    end
    
    % Evaluate connection and check for gap failures
    if signalDetected
        framesCaptured = framesCaptured + 1;
        frameNum = framesCaptured;
        
        if isConnected
            % If the header CRC fails repeatedly, we likely crossed a TX loop gap!
            if rxDiagnostics.headerCRCErrorFlag
                consecutiveFails = consecutiveFails + 1;
            else
                consecutiveFails = 0;
            end
            
            % --- AUTO RECOVERY ---
            % Diagnostic confirmed: BER=0 but CRC=0 after TX loop gap.
            % The decoder is mathematically correct but the header framing
            % drifted by the loop-boundary glitch. Fix: only un-camp the
            % sync search — preserve the rolling signalBuffer so the
            % filter state stays valid. Do NOT skip frames.
            if consecutiveFails >= 3
                fprintf('|  %02.0f%%     | [GAP FIX]   |   -----   |   -----   | Re-calibrating phase lock...\n', (framesCaptured/framesToCapture)*100);
                % Only clear the sync/camp/channel functions.
                % helperOFDMRxFrontEnd is intentionally NOT cleared — its
                % persistent signalBuffer contains live IQ data and must
                % keep rolling to avoid decoding from a zero-padded buffer.
                clear helperOFDMRx helperOFDMRxSearch helperOFDMChannelEstimation;
                signalDetected = false;
                isConnected = false;
                consecutiveFails = 0;
                sysParam.timingAdvance = 0; % Reset timing so FrontEnd outputs from buffer start
                % NO frame skip — let the natural scan find the next real sync.
                continue;
            end
            
            framesSynced = framesSynced + 1;
            numErrors   = sum(xor(transportBlk(1:sysParam.trBlkSize).', rxDataBits));
            BER(frameNum) = numErrors / sysParam.trBlkSize;

                % --- PLOT RAW POST-DEMODULATION DATA ---
                if dataParams.enableScopes
                    % Create a new figure (Figure 2 so it doesn't overwrite your others)
                    figure(2); 
                    
                    % Plot 1: The Heatmap of the Grid
                    subplot(1, 2, 1);
                    % abs() gets the magnitude of the complex numbers
                    imagesc(abs(rxDiagnostics.rawGrid)); 
                    title('Raw Resource Grid (Magnitude)');
                    xlabel('OFDM Symbol Index');
                    ylabel('Subcarrier Index');
                    colorbar;
                    
                    % Plot 2: The Raw Scatter Plot (Pre-Equalization)
                    subplot(1, 2, 2);
                    % We flatten the grid into a 1D list and plot the complex points
                    plot(rxDiagnostics.rawGrid(:), '.b'); 
                    title('Raw Constellation (Pre-EQ)');
                    xlabel('In-Phase');
                    ylabel('Quadrature');
                    axis([-2 2 -2 2]); grid on;
                    
                    drawnow; % Force MATLAB to update the figure instantly
                end
                % ---------------------------------------
                
                % Decode Message
                numBitsToDecode = length(rxDataBits) - mod(length(rxDataBits),7);
                recData = char(bit2int(reshape(rxDataBits(1:numBitsToDecode),7,[]),7));
                
                % Save as char array (not MATLAB string object)
                lastMessage = recData; 

                % --- Estimate SNR via post-equalization EVM (QPSK hard decisions) ---
                eqData = rxDiagnostics.rxConstellationData(:);
                if ~isempty(eqData)
                    decisions  = (sign(real(eqData)) + 1j*sign(imag(eqData))) / sqrt(2);
                    noisePow   = mean(abs(eqData - decisions).^2);
                    sigPow     = mean(abs(decisions).^2);
                    SNR_dB     = 10 * log10(sigPow / max(noisePow, 1e-10));
                else
                    SNR_dB = NaN;
                end

                % Store demodulated information for export
                demodulatedData(dataIdx).Frame         = frameNum;
                demodulatedData(dataIdx).BER           = currentBER;
                demodulatedData(dataIdx).Message       = lastMessage;
                demodulatedData(dataIdx).TxBits        = transportBlk(1:sysParam.trBlkSize).'; % known TX bits (ground truth)
                demodulatedData(dataIdx).RawBits       = rxDataBits;                           % received decoded bits
                demodulatedData(dataIdx).RawGrid       = rxDiagnostics.rawGrid;                % pre-EQ resource grid (ML input)
                demodulatedData(dataIdx).EqData        = rxDiagnostics.rxConstellationData;    % post-EQ data constellation
                demodulatedData(dataIdx).SNR_dB        = SNR_dB;
                demodulatedData(dataIdx).Timestamp     = datestr(now,'yyyy-mm-dd HH:MM:SS.FFF');
                demodulatedData(dataIdx).headerCRCPass = ~rxDiagnostics.headerCRCErrorFlag;
                demodulatedData(dataIdx).dataCRCPass   = ~rxDiagnostics.dataCRCErrorFlag(end);
                dataIdx = dataIdx + 1; 
                
                % Update Constellation Plot (Restored to MathWorks Helper Format)
                if dataParams.enableScopes
                    constDiag(complex(rxDiagnostics.rxConstellationHeader(:)), ...
                              complex(rxDiagnostics.rxConstellationData(:)));
                end
            end
            
            % Update Spectrum Analyzer (if enabled)
            if dataParams.enableScopes
                spectrumAnalyze(rxWaveform);
            end
            
            % --- PRINT TABLE ROW (Every 100 frames) ---
            if mod(frameNum, 100) == 0
                % Calculate progress percentage
                progress = (frameNum / dataParams.numFrames) * 100;
                
                % Set status string
                if isConnected
                    statusStr = 'LOCKED   ';
                else
                    statusStr = 'SEARCHING';
                end
                
                % Truncate message and clean newlines (char-safe)
                maxLen = min(length(lastMessage), 24);
                msgDisplay = lastMessage(1:maxLen);
                msgDisplay = strrep(msgDisplay, newline, ' '); 
                
                % Print formatted row
                fprintf('| %3.0f%%     |  %s  |  %.4f   |   %4d    | %s\n', ...
                    progress, statusStr, currentBER, toverflow, msgDisplay);
            end
        end
    end

% Final Summary
fprintf('======================================================================================\n');
fprintf('Simulation complete!\n');
validBER = BER(BER~=0);
if isempty(validBER), avgBERDisplay = 0; else, avgBERDisplay = mean(validBER); end
fprintf('Total Frames: %d | Frames Synced: %d | Average BER: %.5f\n', ...
    dataParams.numFrames, framesSynced, avgBERDisplay);
if ~loopbackMode, release(radio); end

% --- Save 1: Versioned timestamped file (never overwritten, safe archive) ---
save(captureFilename, 'demodulatedData', 'sysParam');
fprintf('Capture saved : %s\n', captureFilename);

% --- Save 2: Fixed-name file for quick access by plot_ofdm_grid.m etc. ---
latestFile = fullfile(fileparts(mfilename('fullpath')), 'OFDM_Demodulated_Data.mat');
save(latestFile, 'demodulatedData', 'sysParam');

% --- Remove flag file so TX knows to stop ---
if txWaitForRX && exist(flagFile, 'file')
    delete(flagFile);
    fprintf('Flag removed: TX will stop after its current frame.\n');
end

% --- Save 3: JSON metadata sidecar (human-readable, Python/ML pipeline friendly) ---
meta.captureTime       = captureTimestamp;
meta.numFramesCaptured = framesCaptured;
meta.numFramesSynced   = framesSynced;
meta.avgBER            = mean(BER(BER > 0));
meta.centerFreq_Hz     = centerFrequency;
meta.sampleRate_Hz     = sampleRate;
meta.modOrder          = sysParam.modOrder;
meta.FFTLength         = sysParam.FFTLen;
meta.CPLength          = sysParam.CPLen;
meta.usedSubcarriers   = sysParam.usedSubCarr;
meta.numSymPerFrame    = sysParam.numSymPerFrame;
jsonFile = strrep(captureFilename, '.mat', '_metadata.json');
fid = fopen(jsonFile, 'w');
fprintf(fid, '%s', jsonencode(meta));
fclose(fid);
fprintf('Metadata saved: %s\n', jsonFile);