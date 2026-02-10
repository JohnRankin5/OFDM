% The chosen set of OFDM parameters:
OFDMParams.FFTLength              = 128;   % FFT length
OFDMParams.CPLength               = 32;    % Cyclic prefix length
OFDMParams.NumSubcarriers         = 90;    % Number of sub-carriers in the band
OFDMParams.Subcarrierspacing      = 30e3;  % Sub-carrier spacing of 30 KHz
OFDMParams.PilotSubcarrierSpacing = 9;     % Pilot sub-carrier spacing
OFDMParams.channelBW              = 3e6;   % Bandwidth of the channel 3 MHz

% Data Parameters
dataParams.modOrder       = 4;   % Data modulation order
dataParams.coderate       = "1/2";   % Code rate
dataParams.numSymPerFrame = 25;   % Number of data symbols per frame
dataParams.numFrames      = 3000;   % Number of frames to transmit
dataParams.enableScopes   = true;                    % Switch to enable or disable the visibility of scopes
dataParams.verbosity      = false;                    % Control to print the output diagnostics at each level of receiver processing
dataParams.printData      = true;                    % Control to print the output decoded data


radioDevice            = "PLUTO";   % Choose radio device for reception
centerFrequency        = 9.15e8;   % Center Frequency
gain                   = 10;   % Set radio gain









%Make sure the right device is selected and the correct parameter are set
[sysParam,txParam,transportBlk] = helperOFDMSetParamsSDR(OFDMParams,dataParams);
sampleRate                       = sysParam.scs*sysParam.FFTLen;                % Sample rate of signal

ofdmRx = helperGetRadioParams(sysParam,radioDevice,sampleRate,centerFrequency,gain);
[radio,spectrumAnalyze,constDiag] = helperGetRadioRxObj(ofdmRx);

 % 
 % ofdmRx                   = sdrrx('Pluto', ...
 %    'RadioID', 'usb:1', ...
 %    'CenterFrequency', centerFrequency, ...
 %    'BasebandSampleRate', sampleRate, ...
 %    "SamplesPerFrame", 32768, ...
 %    'OutputDataType', 'double', ...
 %    'GainSource', 'AGC Fast Attack');





 % 1. Define the Serial Number for the Receiver
targetSerialRx = '1044739a470b0002ffff270027b37feec0'; 

% 2. Find all connected Plutos
radios = findPlutoRadio;
rxRadioID = '';

% 3. Loop through them to find the match
for i = 1:length(radios)
    if strcmp(radios(i).SerialNum, targetSerialRx)
        rxRadioID = radios(i).RadioID; % Grab the correct 'usb:X' ID
        break;
    end
end

% 4. Error check: Did we find it?
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











% Clear variables
clear helperOFDMRx helperOFDMRxFrontEnd helperOFDMRxSearch helperOFDMFrequencyOffset;
errorRate = comm.ErrorRate();
toverflow = 0; 
rxObj = helperOFDMRxInit(sysParam);
BER = zeros(1,dataParams.numFrames);

% Status tracking variables
framesSynced = 0;
lastMessage = "Waiting for data...";
currentBER = 0;

% Print the Fixed-Width Header
fprintf('\nStarting Receiver...\n');
fprintf('======================================================================================\n');
fprintf('| Progress |   Status    |    BER    | Underruns | Last Message                     \n');
fprintf('|----------|-------------|-----------|-----------|----------------------------------\n');

% --- MAIN LOOP ---
for frameNum = 1:dataParams.numFrames
    sysParam.frameNum = frameNum;
    
    % Receive Data
    [rxWaveform, ~, overflow] = radio();
    toverflow = toverflow + overflow;
    
    % Only process if no overflow
    if ~overflow
        rxIn = helperOFDMRxFrontEnd(rxWaveform,sysParam,rxObj);
        [rxDataBits,isConnected,toff,rxDiagnostics] = helperOFDMRx(rxIn,sysParam,rxObj);
        sysParam.timingAdvance = toff;
        
        % --- IF SIGNAL IS LOCKED ---
        if isConnected
            framesSynced = framesSynced + 1;
            
            % Calculate BER
            berVals = errorRate(transportBlk((1:sysParam.trBlkSize)).', rxDataBits);
            BER(frameNum) = berVals(1);
            currentBER = berVals(1);
            
            % Decode Message
            numBitsToDecode = length(rxDataBits) - mod(length(rxDataBits),7);
            recData = char(bit2int(reshape(rxDataBits(1:numBitsToDecode),7,[]),7));
            
            % Save message for the table display
            lastMessage = string(recData); 
            
            % Update Constellation Plot (if enabled)
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
                statusStr = "LOCKED   ";
            else
                statusStr = "SEARCHING";
            end
            
            % Truncate message if it is too long (prevents table breaking)
            msgDisplay = extractBefore(lastMessage, min(strlength(lastMessage)+1, 25));
            
            % Print formatted row
            % %-8.0f aligns the number to the left
            fprintf('| %3.0f%%     |  %s  |  %.4f   |   %4d    | %s\n', ...
                progress, statusStr, currentBER, toverflow, msgDisplay);
        end
    end
end

% Final Summary
fprintf('======================================================================================\n');
fprintf('Simulation complete!\n');
fprintf('Total Frames: %d | Frames Synced: %d | Average BER: %.5f\n', ...
    dataParams.numFrames, framesSynced, mean(BER(BER~=0)));
release(radio);



































% % Clear all the function data as they contain some persistent variables
% clear helperOFDMRx helperOFDMRxFrontEnd helperOFDMRxSearch helperOFDMFrequencyOffset;
% close all;
% 
% errorRate = comm.ErrorRate();
% toverflow = 0; % Receiver overflow count
% rxObj = helperOFDMRxInit(sysParam);
% BER = zeros(1,dataParams.numFrames);
% for frameNum = 1:dataParams.numFrames
%     sysParam.frameNum = frameNum;
%     [rxWaveform, ~, overflow] = radio();
% 
%     toverflow = toverflow + overflow;
% 
%     % Run the receiver front-end only when there is no overflow
%     if ~overflow
%         rxIn = helperOFDMRxFrontEnd(rxWaveform,sysParam,rxObj);
% 
%         % Run the receiver processing
%         [rxDataBits,isConnected,toff,rxDiagnostics] = helperOFDMRx(rxIn,sysParam,rxObj);
%         sysParam.timingAdvance = toff;
% 
%         % Collect bit and frame error statistics
%         if isConnected
%             % Continuously update the bit error rate using the |comm.ErrorRate|
%             % System object
%             berVals = errorRate(...
%                 transportBlk((1:sysParam.trBlkSize)).', ...
%                 rxDataBits);
%             BER(frameNum) = berVals(1);
%             if dataParams.printData
%                 % As each character in the data is encoded by 7 bits, decode the received data up to last multiples of 7
%                 numBitsToDecode = length(rxDataBits) - mod(length(rxDataBits),7);
%                 recData = char(bit2int(reshape(rxDataBits(1:numBitsToDecode),7,[]),7));
%                 fprintf('Received data in frame %d: %s',frameNum,recData);
%             end
%         end
% 
%         if isConnected && dataParams.enableScopes
%             constDiag(complex(rxDiagnostics.rxConstellationHeader(:)), ...
%                 complex(rxDiagnostics.rxConstellationData(:)));
%         end
% 
%         if dataParams.enableScopes
%             spectrumAnalyze(rxWaveform);
%         end
%     end
% end
% 
% 
% 
% % Display the mean BER value across all frames
% fprintf('Simulation complete!\nAverage BER = %d',mean(BER))
% release(radio);