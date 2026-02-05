function rxObj = helperOFDMRxInit(sysParam)
%helperOFDMRxInit Initializes receiver
%   This helper function is called once and sets up various receiver
%   objects for use in per-frame processing of transport blocks.
%
%   rxObj = helperOFDMRxInit(sysParam)
%   sysParam - structure of system parameters
%   rxObj - structure of rx parameters and object handles
%

% Copyright 2023 The MathWorks, Inc.

% Create an rx filter object for baseband filtering
rxFilterCoef = helperOFDMFrontEndFilter(sysParam);
rxObj.rxFilter = dsp.FIRFilter('Numerator',rxFilterCoef);

rxObj.pfo = comm.PhaseFrequencyOffset(...
    SampleRate = sysParam.scs*sysParam.FFTLen, ...
    FrequencyOffsetSource="Input port");

end