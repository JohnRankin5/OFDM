% Loads saved OFDM capture data and plots the resource grid with full diagnostics.
% Run from the OFDM/ root directory, or adjust fileName below.

% ---- Select which capture to load ----
% Option A: Always load the latest run (default)
rxFileName = 'R/OFDM_Demodulated_Data.mat';
txFileName = 'R/tx_reference.mat';

% Option B: Load a specific archived capture — uncomment and edit path:
% rxFileName = 'R/captures/capture_2026-03-16_00-33-02.mat';
% txFileName = 'R/captures/tx_reference_2026-03-16_00-33-02.mat';
% ---------------------------------------

% 1. Load RX capture data
if exist(rxFileName, 'file')
    load(rxFileName);
else
    error('File "%s" not found. Run OFDMR_Working.m first.', rxFileName);
end
if isempty(demodulatedData)
    error('Demodulated data is empty.');
end

% 2. Load TX reference data (if available)
hasTxRef = exist(txFileName, 'file');
if hasTxRef
    txRef = load(txFileName);  % contains: txGrid, trBlk, sysParam
    fprintf('TX reference loaded: %s\n', txFileName);
else
    fprintf('[NOTE] tx_reference.mat not found — TX comparison plots will be skipped.\n');
    fprintf('       Run OFDMT.m to generate the TX reference file.\n\n');
end

% 3. Select frame to visualize
frameIndex = 16;
if frameIndex > length(demodulatedData)
    warning('frameIndex=%d exceeds available frames (%d). Using frame 1.', frameIndex, length(demodulatedData));
    frameIndex = 1;
end
selectedFrame = demodulatedData(frameIndex);

% 4. Print full frame diagnostics
fprintf('\n==================================================\n');
fprintf('  Capture Summary  (%d frames total)\n', length(demodulatedData));
fprintf('==================================================\n');
fprintf('Visualizing  : Frame %d of %d\n', selectedFrame.Frame, length(demodulatedData));
fprintf('Timestamp    : %s\n', selectedFrame.Timestamp);
fprintf('Message      : %s\n', selectedFrame.Message);
fprintf('BER          : %.6f\n', selectedFrame.BER);
fprintf('SNR (est.)   : %.2f dB\n', selectedFrame.SNR_dB);
crcStr = {'FAIL','PASS'};   % index 1=false, 2=true
fprintf('Header CRC   : %s\n', crcStr{selectedFrame.headerCRCPass + 1});
fprintf('Data CRC     : %s\n', crcStr{selectedFrame.dataCRCPass + 1});
fprintf('--------------------------------------------------\n');
fprintf('RawGrid size : %d subcarriers x %d symbols\n', ...
    size(selectedFrame.RawGrid, 1), size(selectedFrame.RawGrid, 2));
fprintf('TxBits size  : %d bits\n', length(selectedFrame.TxBits));
fprintf('RxBits size  : %d bits\n', length(selectedFrame.RawBits));
if isfield(selectedFrame, 'TxBits') && ~isempty(selectedFrame.TxBits)
    bitErrors = sum(xor(selectedFrame.TxBits(:), selectedFrame.RawBits(:)));
    fprintf('Bit Errors   : %d / %d\n', bitErrors, length(selectedFrame.TxBits));
end
if exist('sysParam','var')
    fprintf('FFT Length   : %d\n', sysParam.FFTLen);
    fprintf('Mod Order    : %d (QAM-%d)\n', sysParam.modOrder, sysParam.modOrder);
end
fprintf('==================================================\n\n');

% 5. All-frame summary
allBER  = [demodulatedData.BER];
allSNR  = [demodulatedData.SNR_dB];
allHCRC = [demodulatedData.headerCRCPass];
allDCRC = [demodulatedData.dataCRCPass];
fprintf('--- All-Frame Summary ---\n');
fprintf('Avg BER      : %.6f\n', mean(allBER));
fprintf('Avg SNR      : %.2f dB\n', mean(allSNR(~isnan(allSNR))));
fprintf('Header CRC   : %d/%d passed\n', sum(allHCRC), length(allHCRC));
fprintf('Data CRC     : %d/%d passed\n', sum(allDCRC), length(allDCRC));
fprintf('-------------------------\n\n');

rxGrid = selectedFrame.RawGrid;

% ==========================================================================
% FIGURE 1: TX vs RX Resource Grid Comparison
% ==========================================================================
figTitle = sprintf('Frame %d | BER=%.4f | SNR=%.1f dB | %s', ...
    selectedFrame.Frame, selectedFrame.BER, selectedFrame.SNR_dB, selectedFrame.Timestamp);

if hasTxRef
    figure('Name', ['TX vs RX Grid — ' figTitle], 'NumberTitle', 'off', 'Position', [50, 500, 1400, 400]);

    % TX clean grid
    subplot(1, 3, 1);
    imagesc(abs(txRef.txGrid));
    colormap('jet'); colorbar;
    title('TX Grid (Clean, No Noise)');
    ylabel('Subcarrier Index'); xlabel('OFDM Symbol Index');
    axis([1 size(txRef.txGrid,2) 1 size(txRef.txGrid,1)]);
    grid on; set(gca,'Layer','top');

    % RX received grid
    subplot(1, 3, 2);
    imagesc(abs(rxGrid));
    colormap('jet'); colorbar;
    title(sprintf('RX Grid (Received, SNR≈%.1f dB)', selectedFrame.SNR_dB));
    ylabel('Subcarrier Index'); xlabel('OFDM Symbol Index');
    axis([1 size(rxGrid,2) 1 size(rxGrid,1)]);
    grid on; set(gca,'Layer','top');

    % Difference (error) grid
    subplot(1, 3, 3);
    % Align dimensions if mismatch (TX includes sync/ref/header symbols)
    % Align txGrid to rxGrid dimensions:
    %  - txGrid rows: all numSubCar subcarriers (data + pilots)
    %  - rxGrid rows: data subcarriers only (pilots removed by ofdmdemod)
    %  - txGrid cols: all numSymPerFrame symbols (incl. sync at col 1)
    %  - rxGrid cols: numSymPerFrame-1 symbols (sync excluded)
    nSymRx = size(rxGrid, 2);
    txCols = txRef.txGrid(:, end-nSymRx+1:end);  % strip sync symbol (last nSymRx cols)

    % Remove pilot rows from txGrid to match rxGrid row count
    numSubCar = size(txRef.txGrid, 1);
    pilotSpacing = round(numSubCar / size(rxGrid, 1) * ...
        (size(rxGrid,1) / (numSubCar - size(rxGrid,1))));  % estimate pilot spacing
    pilotRows = 1:round(numSubCar / (numSubCar - size(rxGrid, 1))):numSubCar;
    if length(pilotRows) ~= (numSubCar - size(rxGrid,1))
        % Fallback: use naive even spacing
        pilotRows = round(linspace(1, numSubCar, numSubCar - size(rxGrid,1)));
    end
    dataRows = setdiff(1:numSubCar, pilotRows);
    txGridAligned = txCols(dataRows, :);

    if isequal(size(txGridAligned), size(rxGrid))
        diffGrid = abs(txGridAligned - rxGrid);
        imagesc(diffGrid);
        colormap(gca,'hot'); colorbar;
        title('|TX - RX| Error Grid (data subcarriers)');
    else
        % Still mismatched — show info instead
        axis off;
        text(0.5, 0.5, sprintf('Grid size mismatch\ntxGrid: %dx%d  rxGrid: %dx%d', ...
            size(txGridAligned,1), size(txGridAligned,2), size(rxGrid,1), size(rxGrid,2)), ...
            'HorizontalAlignment','center','Units','normalized','FontSize',10);
        title('|TX - RX| Error Grid');
    end
    ylabel('Subcarrier Index'); xlabel('OFDM Symbol Index');
    axis([1 size(rxGrid,2) 1 size(rxGrid,1)]);
    grid on; set(gca,'Layer','top');

else
    % No TX reference — show RX grid only
    figure('Name', figTitle, 'NumberTitle', 'off', 'Position', [50, 500, 900, 400]);
    subplot(1, 2, 1);
    imagesc(abs(rxGrid));
    colormap('jet'); colorbar;
    title(sprintf('RX Resource Grid (Frame %d)', selectedFrame.Frame));
    ylabel('Subcarrier Index'); xlabel('OFDM Symbol Index');
    axis([1 size(rxGrid,2) 1 size(rxGrid,1)]);
    grid on; set(gca,'Layer','top');

    subplot(1, 2, 2);
    complexPoints = rxGrid(:);
    plot(real(complexPoints), imag(complexPoints), '.b', 'MarkerSize', 4);
    title(sprintf('Pre-EQ Constellation | SNR≈%.1f dB', selectedFrame.SNR_dB));
    xlabel('In-Phase'); ylabel('Quadrature');
    axis([-2 2 -2 2]); grid on;
    hold on;
    plot([-2 2],[0 0],'k--','LineWidth',0.5);
    plot([0 0],[-2 2],'k--','LineWidth',0.5);
    hold off;
end

% ==========================================================================
% FIGURE 2: TX vs RX Constellation + Bit Error Map
% ==========================================================================
if hasTxRef
    figure('Name', 'Constellation & Bit Comparison', 'NumberTitle', 'off', 'Position', [50, 50, 1400, 400]);

    % TX ideal constellation
    subplot(1, 3, 1);
    txPoints = txRef.txGrid(:);
    plot(real(txPoints), imag(txPoints), '.g', 'MarkerSize', 4);
    title('TX Constellation (Clean)');
    xlabel('In-Phase'); ylabel('Quadrature');
    axis([-2 2 -2 2]); grid on;
    hold on;
    plot([-2 2],[0 0],'k--','LineWidth',0.5);
    plot([0 0],[-2 2],'k--','LineWidth',0.5);
    hold off;

    % RX received constellation
    subplot(1, 3, 2);
    rxPoints = rxGrid(:);
    plot(real(rxPoints), imag(rxPoints), '.b', 'MarkerSize', 4);
    title(sprintf('RX Constellation (Received) | SNR≈%.1f dB', selectedFrame.SNR_dB));
    xlabel('In-Phase'); ylabel('Quadrature');
    axis([-2 2 -2 2]); grid on;
    hold on;
    plot([-2 2],[0 0],'k--','LineWidth',0.5);
    plot([0 0],[-2 2],'k--','LineWidth',0.5);
    hold off;

    % Bit error map
    subplot(1, 3, 3);
    if isfield(selectedFrame,'TxBits') && ~isempty(selectedFrame.TxBits)
        txB = selectedFrame.TxBits(:);
        rxB = selectedFrame.RawBits(:);
        minLen = min(length(txB), length(rxB));
        errBits = double(xor(txB(1:minLen), rxB(1:minLen)));
        % Reshape into 2D for visualization (aim for roughly square)
        cols = 64;
        rows = ceil(minLen / cols);
        padLen = rows * cols - minLen;
        errMap = reshape([errBits; zeros(padLen,1)], cols, rows)';
        imagesc(errMap);
        colormap(gca, [0.15 0.6 0.15; 0.9 0.2 0.2]); % green=correct, red=error
        title(sprintf('Bit Error Map (%d errors / %d bits)', sum(errBits), minLen));
        xlabel('Bit Index (columns)'); ylabel('Bit Index (rows)');
        colorbar('Ticks',[0,1],'TickLabels',{'Correct','Error'});
    else
        text(0.5,0.5,'TxBits not available\n(re-run RX with updated code)', ...
            'HorizontalAlignment','center','Units','normalized');
    end
end

% ==========================================================================
% FIGURE 3: BER and SNR over all frames
% ==========================================================================
if length(demodulatedData) > 1
    figure('Name', 'Capture Statistics', 'NumberTitle', 'off', 'Position', [1050, 500, 900, 350]);

    subplot(1, 2, 1);
    plot([demodulatedData.Frame], allBER, 'b.-', 'LineWidth', 1.2, 'MarkerSize', 10);
    xlabel('Frame Index'); ylabel('BER');
    title('Per-Frame Bit Error Rate');
    grid on;

    subplot(1, 2, 2);
    plot([demodulatedData.Frame], allSNR, 'r.-', 'LineWidth', 1.2, 'MarkerSize', 10);
    xlabel('Frame Index'); ylabel('SNR (dB)');
    title('Per-Frame Estimated SNR');
    grid on;
end
