% =========================================================================
%                         OFDM RECEIVER SCRIPT
% =========================================================================

% --- 1. PARAMETER SETUP ---
OFDMParams.FFTLength              = 128;   % FFT length
OFDMParams.CPLength               = 32;    % Cyclic prefix length
OFDMParams.NumSubcarriers         = 90;    % Number of sub-carriers
OFDMParams.Subcarrierspacing      = 30e3;  % 30 KHz spacing
OFDMParams.PilotSubcarrierSpacing = 9;     % Pilot spacing
OFDMParams.channelBW              = 3e6;   % 3 MHz Bandwidth

dataParams.modOrder       = 4;     % QPSK
dataParams.coderate       = "1/2"; 
dataParams.numSymPerFrame = 25;    
dataParams.numFrames      = 3000;  % Total frames to listen for
dataParams.enableScopes   = true;  % Show graphs
dataParams.verbosity      = false; 
dataParams.printData      = true;  

radioDevice     = "PLUTO"; 
centerFrequency = 9.15e8;
gain            = 10; 

% Generate System Parameters
[sysParam, txParam, transportBlk] = helperOFDMSetParamsSDR(OFDMParams, dataParams);
sampleRate = sysParam.scs * sysParam.FFTLen; 

% --- 2. CONNECT TO SPECIFIC PLUTO ---
targetSerialRx = '1044739a470b0002ffff270027b37feec0'; 
radios = findPlutoRadio;
rxRadioID = '';

% Find the specific radio
for i = 1:length(radios)
    if strcmp(radios(i).SerialNum, targetSerialRx)
        rxRadioID = radios(i).RadioID;
        break;
    end
end

if isempty(rxRadioID)
    error('Receiver Pluto not found! Check connection.');
end

% Create the Receiver Object (The ONE and ONLY owner of the hardware)
radio = sdrrx('Pluto', ...
    'RadioID', rxRadioID, ... 
    'CenterFrequency', centerFrequency, ...
    'BasebandSampleRate', sampleRate, ...
    'SamplesPerFrame', 32768, ...
    'OutputDataType', 'double', ...
    'GainSource', 'AGC Fast Attack');

disp(['Receiver successfully connected to: ' rxRadioID]);

% --- 3. MANUALLY CREATE SCOPES ---
% (We need these because we removed the helper function that usually makes them)

% Spectrum Analyzer
spectrumAnalyze = spectrumAnalyzer( ...
    'SampleRate', sampleRate, ...
    'SpectrumType', 'Power', ...
    'PlotAsTwoSidedSpectrum', true, ...
    'Title', 'Received OFDM Spectrum', ...
    'ShowLegend', false);

% Constellation Diagram
constDiag = comm.ConstellationDiagram( ...
    'Title', 'Received Constellation (Data & Header)', ...
    'ShowReferenceConstellation', false, ...
    'XLimits', [-1.5 1.5], 'YLimits', [-1.5 1.5]);

% --- 4. INITIALIZE RECEIVER LOOP VARIABLES ---
% Clear old helper data
clear helperOFDMRx helperOFDMRxFrontEnd helperOFDMRxSearch helperOFDMFrequencyOffset;

errorRate = comm.ErrorRate();
toverflow = 0; 
rxObj = helperOFDMRxInit(sysParam);
BER = zeros(1, dataParams.numFrames);

% Dashboard Variables
framesSynced = 0;
lastMessage = "Waiting for data...";
currentBER = 0;

% --- 5. MAIN LOOP (THE DASHBOARD) ---
fprintf('\nStarting Receiver...\n');
fprintf('======================================================================================\n');
fprintf('| Progress |   Status    |    BER    | Underruns | Last Message                     \n');
fprintf('|----------|-------------|-----------|-----------|----------------------------------\n');

for frameNum = 1:dataParams.numFrames
    sysParam.frameNum = frameNum;
    
    % Get Data from Radio
    [rxWaveform, ~, overflow] = radio();
    toverflow = toverflow + overflow;
    
    % Process Data (Only if hardware buffer didn't overflow)
    if ~overflow
        rxIn = helperOFDMRxFrontEnd(rxWaveform, sysParam, rxObj);
        [rxDataBits, isConnected, toff, rxDiagnostics] = helperOFDMRx(rxIn, sysParam, rxObj);
        sysParam.timingAdvance = toff;
        
        % If Signal Found (Synced)
        if isConnected
            framesSynced = framesSynced + 1;
            
            % Calculate BER
            berVals = errorRate(transportBlk((1:sysParam.trBlkSize)).', rxDataBits);
            BER(frameNum) = berVals(1);
            currentBER = berVals(1);
            
            % Decode Message
            numBitsToDecode = length(rxDataBits) - mod(length(rxDataBits), 7);
            recData = char(bit2int(reshape(rxDataBits(1:numBitsToDecode), 7, []), 7));
            lastMessage = string(recData); 
            
            % Update Constellation Plot
            if dataParams.enableScopes
                allDots = [complex(rxDiagnostics.rxConstellationHeader(:)); ...
                complex(rxDiagnostics.rxConstellationData(:))];
                constDiag(allDots);
            end
        end
        
        % Update Spectrum Analyzer
        if dataParams.enableScopes
            spectrumAnalyze(rxWaveform);
        end
        
        % --- PRINT DASHBOARD ROW (Every 100 frames) ---
        if mod(frameNum, 100) == 0
            % Calculate progress percentage
            progress = (frameNum / dataParams.numFrames) * 100;
            
            % Set status string
            if isConnected
                statusStr = "LOCKED   ";
            else
                statusStr = "SEARCHING";
            end
            
            % Clean up message for display
            msgDisplay = extractBefore(lastMessage, min(strlength(lastMessage)+1, 25));
            % Remove newlines to keep table straight
            msgDisplay = replace(msgDisplay, newline, ' '); 
            
            % Print formatted row
            fprintf('| %3.0f%%     |  %s  |  %.4f   |   %4d    | %s\n', ...
                progress, statusStr, currentBER, toverflow, msgDisplay);
        end
    end
end

% --- 6. FINAL SUMMARY ---
fprintf('======================================================================================\n');
fprintf('Simulation complete!\n');
fprintf('Total Frames: %d | Frames Synced: %d | Average BER: %.5f\n', ...
    dataParams.numFrames, framesSynced, mean(BER(BER~=0)));

% Release hardware
release(radio);