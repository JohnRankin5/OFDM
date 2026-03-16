% Loads saved OFDM capture data and plots the resource grid with full diagnostics.
% Run from the OFDM/ root directory, or adjust fileName below.

% ---- Select which capture to load ----
% Option A: Always load the latest run (default)
fileName = 'R/OFDM_Demodulated_Data.mat';

% Option B: Load a specific archived capture — uncomment and edit path:
% fileName = 'R/captures/capture_2026-03-16_00-33-02.mat';
% ---------------------------------------

% 1. Load the data
if exist(fileName, 'file')
    load(fileName);
else
    error('File "%s" not found. Run OFDMR_Working.m first.', fileName);
end

if isempty(demodulatedData)
    error('Demodulated data is empty.');
end

% 2. Select frame to visualize
frameIndex = 4;
selectedFrame = demodulatedData(frameIndex);

% 3. Print full frame diagnostics to console
fprintf('\n==================================================\n');
fprintf('  Capture Summary  (%d frames total)\n', length(demodulatedData));
fprintf('==================================================\n');
fprintf('Visualizing  : Frame %d of %d\n', selectedFrame.Frame, length(demodulatedData));
fprintf('Timestamp    : %s\n', selectedFrame.Timestamp);
fprintf('Message      : %s\n', selectedFrame.Message);
fprintf('BER          : %.6f\n', selectedFrame.BER);
fprintf('SNR (est.)   : %.2f dB\n', selectedFrame.SNR_dB);
fprintf('Header CRC   : %s\n', upper(string(selectedFrame.headerCRCPass)));
fprintf('Data CRC     : %s\n', upper(string(selectedFrame.dataCRCPass)));
fprintf('--------------------------------------------------\n');
fprintf('RawGrid size : %d subcarriers x %d symbols\n', ...
    size(selectedFrame.RawGrid, 1), size(selectedFrame.RawGrid, 2));
fprintf('RawBits size : %d bits\n', length(selectedFrame.RawBits));
if exist('sysParam','var')
    fprintf('FFT Length   : %d\n', sysParam.FFTLen);
    fprintf('Mod Order    : %d (%s)\n', sysParam.modOrder, ...
        sprintf('QAM-%d', sysParam.modOrder));
end
fprintf('==================================================\n\n');

% 4. Print BER and SNR summary across all captured frames
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

% 5. Extract raw grid
rawGrid = selectedFrame.RawGrid;

% 6. Build figure title with key stats
figTitle = sprintf('Frame %d | BER=%.4f | SNR=%.1f dB | %s', ...
    selectedFrame.Frame, selectedFrame.BER, selectedFrame.SNR_dB, ...
    selectedFrame.Timestamp);

figure('Name', figTitle, 'NumberTitle', 'off', 'Position', [100, 100, 1200, 450]);

% Plot 1: Magnitude Heatmap
subplot(1, 2, 1);
imagesc(abs(rawGrid));
colormap('jet');
colorbar;
title(sprintf('Resource Grid Heatmap (Frame %d)', selectedFrame.Frame));
ylabel('Subcarrier Index (Frequency)');
xlabel('OFDM Symbol Index (Time)');
axis([1 size(rawGrid,2) 1 size(rawGrid,1)]);
grid on;
set(gca, 'Layer', 'top');

% Plot 2: Pre-Equalization Constellation
subplot(1, 2, 2);
complexPoints = rawGrid(:);
plot(real(complexPoints), imag(complexPoints), '.b', 'MarkerSize', 4);
title(sprintf('Pre-Equalization Constellation | SNR≈%.1f dB', selectedFrame.SNR_dB));
xlabel('In-Phase (Real)');
ylabel('Quadrature (Imaginary)');
axis([-2 2 -2 2]);
grid on;
hold on;
plot([-2 2], [0 0], 'k--', 'LineWidth', 0.5);
plot([0 0], [-2 2], 'k--', 'LineWidth', 0.5);
hold off;

% 7. Optional: BER and SNR across all frames
if length(demodulatedData) > 1
    figure('Name', 'Capture Statistics', 'NumberTitle', 'off', 'Position', [100, 600, 1000, 350]);

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
