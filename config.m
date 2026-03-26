% =============================================================================
% config.m  —  SHARED OFDM SYSTEM CONFIGURATION
% =============================================================================
% Edit this file to keep TX and RX parameters in sync.
% Both OFDMT.m and OFDMR_Working.m load this file automatically at startup.
% Only parameters that MUST match on both sides live here.
% TX-specific and RX-specific settings remain in their own scripts.
% =============================================================================

%% OFDM Physical Layer  (must be identical on TX and RX)
OFDMParams.FFTLength              = 128;   % FFT length
OFDMParams.CPLength               = 32;    % Cyclic prefix length
OFDMParams.NumSubcarriers         = 90;    % Active sub-carriers
OFDMParams.Subcarrierspacing      = 30e3;  % Sub-carrier spacing (Hz)
OFDMParams.PilotSubcarrierSpacing = 9;     % Pilot sub-carrier spacing
OFDMParams.channelBW              = 3e6;   % Channel bandwidth (Hz)

%% Modulation & Coding  (must be identical on TX and RX)
dataParams.modOrder       = 4;     % 4=QPSK | 16=16QAM | 64=64QAM | 256=256QAM
dataParams.coderate       = '1/2'; % '1/2' | '2/3' | '3/4' | '5/6'
dataParams.numSymPerFrame = 25;    % OFDM symbols per frame (must be >= 4; do not change unless redesigning the frame)

%% RF  (must be identical on TX and RX)
centerFrequency = 9.15e8;          % Center frequency in Hz (915 MHz)

%% Frame Counts
txNumFrames  = 1000; % TX: safety cap on max frames (used only if txWaitForRX=false)
rxNumFrames  = 1000; % RX: how many valid payload data frames to capture and save

% Set true  = TX runs until RX finishes (recommended — no timing guesswork)
% Set false = TX runs for exactly txNumFrames then stops regardless of RX
txWaitForRX = true;

%% Display & Logging
dataParams.enableScopes = false; % Set to false to disable live plotting and speed up captures
dataParams.printData    = false;  % Set to false to hide decoded message strings in the console
dataParams.verbosity    = false; % Verbose debug output

%% Debug / Loopback Mode
% Set loopbackMode = true to test the full RX pipeline WITHOUT hardware.
% The TX waveform is generated internally and fed straight into the RX decoder.
% No PlutoSDR required. Use this to verify code correctness before going live.
loopbackMode   = false;   % true = software loopback | false = real PlutoSDR hardware
loopbackSNR_dB = 25;      % AWGN noise level in loopback (dB). Higher = cleaner signal.

%% TX Payload
% Message to transmit. Capacity = (numSymPerFrame - 3) * 80 * 2 * 0.5 / 7 ASCII chars per frame.
% With numSymPerFrame=25 → ~246 chars | With numSymPerFrame=10 → ~80 chars.
% Shorter messages repeat to fill the frame; longer are truncated.
dataParams.message = 'OFDM Transceiver V2: By bypassing physical DMA burst limits, the Two-Stage stream algorithm guarantees infinite stable transmission. Auto-Recovery 100% Active. | ';

% --- Alternatively: send raw random bytes or bits ---
% Option A — Random printable ASCII characters (still decoded as text on RX):
%   dataParams.message = char(randi([32 126], 1, 50));  % 50 random printable chars
%
% Option B — Raw random bytes (full 0-255 range, decoded as raw bits on RX):
%   dataParams.message = char(randi([0 255], 1, 50));   % 50 random bytes
%
% Option C — Skip the message entirely and send pure random bits
%             (set directly in helperOFDMSetParamsSDR.m, bypasses text encoding):
%   payload = randi([0 1], 1, sysParam.trBlkSize);      % random bits, exact frame size
% ----------------------------------------------------
