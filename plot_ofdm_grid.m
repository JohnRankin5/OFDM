% plot_ofdm_grid.m
% This script loads the saved OFDM Demodulated Data and plots the resource grid

% 1. Load the data
fileName = 'R/OFDM_Demodulated_Data.mat';
if exist(fileName, 'file')
    load(fileName);
else
    error('File %s not found. Please run the simulation first.', fileName);
end

if isempty(demodulatedData)
    error('Demodulated data is empty.');
end

% 2. Select a frame to visualize (e.g., the first successfully decoded frame)
frameIndex = 1;
selectedFrame = demodulatedData(frameIndex);

fprintf('\n=================================\n');
fprintf('Visualizing Frame %d \n', selectedFrame.Frame);
fprintf('=================================\n');
fprintf('Message     : %s\n', selectedFrame.Message);
fprintf('BER         : %.4f\n', selectedFrame.BER);

% 3. Extract the raw grid (Complex matrix of 80x24)
rawGrid = selectedFrame.RawGrid;

fprintf('\n--- Data Structure Sizes ---\n');
fprintf('demodulatedData Array : %d x %d\n', size(demodulatedData, 1), size(demodulatedData, 2));
fprintf('RawBits Length        : %d x %d\n', size(selectedFrame.RawBits, 1), size(selectedFrame.RawBits, 2));
fprintf('RawGrid Dimensions    : %d (Subcarriers) x %d (Symbols)\n', size(rawGrid, 1), size(rawGrid, 2));
fprintf('=================================\n\n');

% 4. Create the figure
figure('Name', sprintf('OFDM Resource Grid Analysis - Frame %d', selectedFrame.Frame), 'NumberTitle', 'off', 'Position', [100, 100, 1000, 400]);

% Plot 1: Magnitude Heatmap (Frequency vs Time)
subplot(1, 2, 1);
% Calculate the magnitude (strength) of each complex symbol in the grid
gridMagnitude = abs(rawGrid);

% Plot as a heatmap
imagesc(gridMagnitude);
colormap('jet');
colorbar;

title('Resource Grid Heatmap (Magnitude)');
ylabel('Subcarrier Index (Frequency)');
xlabel('OFDM Symbol Index (Time)');
% Adjust axis to show that frequency goes from 1 to 80, and time from 1 to 24
axis([1 24 1 80]); 

% Add grid lines for clarity
grid on;
set(gca, 'Layer', 'top');

% Plot 2: Scatter Plot (Constellation)
subplot(1, 2, 2);
% Flatten the 2D grid into a 1D array of complex numbers for the scatter plot
complexPoints = rawGrid(:);

% Plot the real (In-Phase) vs imaginary (Quadrature) parts
plot(real(complexPoints), imag(complexPoints), '.b');
title('Pre-Equalization Constellation');
xlabel('In-Phase (Real)');
ylabel('Quadrature (Imaginary)');
axis([-2 2 -2 2]);
grid on;

% Add a horizontal and vertical line at 0
hold on;
plot([-2 2], [0 0], 'k--', 'LineWidth', 0.5);
plot([0 0], [-2 2], 'k--', 'LineWidth', 0.5);
hold off;
