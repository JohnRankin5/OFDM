% diagnose_gap.m  — Run this standalone to inspect the GAP FIX behaviour
% WITHOUT touching any hardware. Loads the last real capture and replays it.
% Usage: run from the OFDM root, or from the R/ folder.
close all; clear; clc;

run(fullfile(fileparts(mfilename('fullpath')), '..', 'config.m'));
dataParams.numFrames = rxNumFrames;
radioDevice = 'PLUTO';
gain = 10;
[sysParam, txParam, transportBlk] = helperOFDMSetParamsSDR(OFDMParams, dataParams);
% Skip hardware init — we only need sysParam for analysis
% rxObj = helperGetRadioRxObj(sysParam, radioDevice, gain);

%% Load a saved capture
captureFile = fullfile(fileparts(mfilename('fullpath')), 'captures', 'capture_2026-03-23_22-06-02.mat');
if ~exist(captureFile,'file')
    % Fall back to any capture present
    hits = dir(fullfile(fileparts(mfilename('fullpath')), 'captures', 'capture_*.mat'));
    [~,idx] = sort([hits.datenum],'descend');
    captureFile = fullfile(hits(idx(1)).folder, hits(idx(1)).name);
end
fprintf('Loading: %s\n', captureFile);
S = load(captureFile, 'demodulatedData', 'sysParam');
fprintf('Loaded %d frames.\n\n', numel(S.demodulatedData));

%% Show the first gap: find 3 consecutive headerCRC failures
N   = numel(S.demodulatedData);
BER = [S.demodulatedData.BER];
crc = ~[S.demodulatedData.headerCRCPass];   % 1 = fail

gapStart = NaN;
for k = 3:N
    if crc(k) && crc(k-1) && crc(k-2)
        gapStart = k-2;
        break;
    end
end

if isnan(gapStart)
    fprintf('No 3-consecutive CRC failures found — data looks clean!\n');
else
    fprintf('First triple CRC-failure starts at frame %d (%.1f%%)\n\n', ...
        gapStart, 100*gapStart/N);
    fprintf('BER around gap:\n');
    idxRange = max(1,gapStart-5) : min(N, gapStart+10);
    for k = idxRange
        marker = '';
        if crc(k), marker = '  <-- CRC FAIL'; end
        fprintf('  Frame %4d  BER=%.4f  CRC=%d%s\n', k, BER(k), ~crc(k), marker);
    end
end

%% Measure TX loop period from sync intervals (if msgTimestamp present)
ts = {S.demodulatedData.Timestamp};
if ~isempty(ts{1})
    t  = datenum(ts, 'yyyy-mm-dd HH:MM:SS.FFF') * 86400;  % seconds
    dt = diff(t);
    fprintf('\nMean inter-frame interval: %.4f ms (expected %.4f ms)\n', ...
        1000*mean(dt), 1000 * sysParam.txWaveformSize / (sysParam.scs*sysParam.FFTLen));
end
