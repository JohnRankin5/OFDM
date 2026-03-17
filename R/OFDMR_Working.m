% =============================================================================
% OFDM RECEIVER
% Shared parameters (OFDMParams, modulation, RF, message) live in config.m.
% Edit config.m to keep TX and RX in sync.
% =============================================================================

% Reset persistent state from any previous run.
% helperOFDMRx uses 'persistent camped' — if not cleared, every new run
% inherits camped=true and decodes without re-syncing → BER = 0.5 every frame.
clear helperOFDMRx helperOFDMRxSearch helperOFDMRxFrontEnd helperOFDMChannelEstimation;

% Load shared parameters
run(fullfile(fileparts(mfilename('fullpath')), '..', 'config.m'));

% RX-specific parameters
dataParams.numFrames    = rxNumFrames; % Set in config.m → rxNumFrames
dataParams.enableScopes = true;  % Show spectrum/constellation scopes
dataParams.verbosity    = false; % Verbose debug output
dataParams.printData    = true;  % Print decoded message to console
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
    % Repeat to fill at least 32768 samples (same as radio SamplesPerFrame)
    nRep = ceil(32768 / length(loopbackWaveform)) + 1;
    loopbackWaveform = repmat(loopbackWaveform, nRep, 1);
    radioLB = @() deal(loopbackWaveform(1:32768), 0, false);
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
    flagFile = fullfile(fileparts(mfilename('fullpath')), 'rx_running.flag');
    fid = fopen(flagFile, 'w'); fclose(fid);
    fprintf('Flag created: TX will broadcast until this RX session ends.\n');
end

fprintf('\nWaiting for signal (receiver will run indefinitely until signal is found)...\n');

% --- MAIN LOOP ---
framesCaptured = 0;
signalDetected = false;

while framesCaptured < dataParams.numFrames
    sysParam.frameNum = framesCaptured + 1;
    
    % Receive Data
    if loopbackMode
        % Loopback: add AWGN noise to the TX waveform each iteration
        [rxWaveform, overflow, ~] = radio();
        noisePwr   = 10^(-loopbackSNR_dB/10) * mean(abs(rxWaveform).^2);
        rxWaveform = rxWaveform + sqrt(noisePwr/2)*(randn(size(rxWaveform))+1j*randn(size(rxWaveform)));
        overflow   = false;
    else
        [rxWaveform, ~, overflow] = radio();
    end
    toverflow = toverflow + overflow;
    
    % Only process if no overflow
    if ~overflow
        rxIn = helperOFDMRxFrontEnd(rxWaveform,sysParam,rxObj);
        [rxDataBits,isConnected,toff,rxDiagnostics] = helperOFDMRx(rxIn,sysParam,rxObj);
        sysParam.timingAdvance = toff;
        
        % Detect signal for the first time
        if isConnected && ~signalDetected
            signalDetected = true;
            fprintf('Signal detected! Starting capture of %d frames...\n', dataParams.numFrames);
            
            % Print the Fixed-Width Header
            fprintf('======================================================================================\n');
            fprintf('| Progress |   Status    |    BER    | Underruns | Last Message                     \n');
            fprintf('|----------|-------------|-----------|-----------|----------------------------------\n');
        end
        
        % Only process and count loops if we have begun detection
        if signalDetected
            framesCaptured = framesCaptured + 1;
            frameNum = framesCaptured;
            
            % --- IF SIGNAL IS LOCKED ---
            if isConnected
                framesSynced = framesSynced + 1;
                
                % Per-frame BER: directly compare this frame's bits (not cumulative)
                numErrors   = sum(xor(transportBlk(1:sysParam.trBlkSize).', rxDataBits));
                currentBER  = numErrors / sysParam.trBlkSize;
                BER(frameNum) = currentBER;
                
                % Also feed into comm.ErrorRate for the overall session average (final summary only)
                errorRate(transportBlk((1:sysParam.trBlkSize)).', rxDataBits);

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