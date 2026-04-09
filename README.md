# OFDM Transceiver — ML Dataset Capture Pipeline

A real-hardware OFDM transceiver built on two **ADALM-PLUTO (PlutoSDR)** radios that captures perfectly synchronized TX/RX frame pairs for machine-learning research. The pipeline generates up to **10,000 unique frames** of labeled IQ data in PyTorch-ready format.

---

## Table of Contents

- [System Overview](#system-overview)
- [Hardware Requirements](#hardware-requirements)
- [Software Requirements](#software-requirements)
- [Repository Structure](#repository-structure)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Architecture Deep Dive](#architecture-deep-dive)
  - [Frame Structure](#frame-structure)
  - [Transmitter Pipeline](#transmitter-pipeline)
  - [Receiver Pipeline](#receiver-pipeline)
  - [TX/RX Frame Matching (K-Lock)](#txrx-frame-matching-k-lock)
  - [Auto-Recovery Mechanisms](#auto-recovery-mechanisms)
- [Dataset Format](#dataset-format)
- [Visualization & Diagnostics](#visualization--diagnostics)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         MATLAB Host Machine                         │
│                                                                     │
│  ┌──────────────┐   USB    ┌──────────┐   OTA   ┌──────────┐  USB  │
│  │   OFDMT.m    │─────────▶│ PlutoSDR │~~~~~~~~~│ PlutoSDR │──────▶│
│  │ (Transmitter)│          │   (TX)   │  915MHz │   (RX)   │       │
│  └──────────────┘          └──────────┘         └──────────┘       │
│                                                        │            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    OFDMR_Working.m (Receiver)                │   │
│  │  Stage 1: Hardware capture → RAM buffer                      │   │
│  │  Stage 2: Offline decode → K-Lock sync → BER verify         │   │
│  │  Output : OFDM_Demodulated_Data.mat (paired TX+RX frames)   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌───────────────────┐    ┌────────────────────┐                   │
│  │create_pytorch_    │    │  display_dataset.py │                   │
│  │dataset.py         │    │  plot_ofdm_grid.m   │                   │
│  │(.mat → .pth)      │    │  (diagnostics)      │                   │
│  └───────────────────┘    └────────────────────┘                   │
└─────────────────────────────────────────────────────────────────────┘
```

The TX and RX each run on their own PlutoSDR connected via USB. They do **not** share a clock — the K-Lock synchronization algorithm resolves timing ambiguity over the air.

---

## Hardware Requirements

| Component | Specification |
|---|---|
| PlutoSDR × 2 | ADALM-PLUTO (one TX, one RX) |
| USB 2.0 ports × 2 | One per radio |
| Host PC | Windows 10/11, ≥16 GB RAM recommended |
| RF path | Direct antenna-to-antenna or short coax + attenuator |

> **Note:** Both radios must be connected **before** starting MATLAB. Use `findPlutoRadio` in MATLAB to verify serial numbers match `config.m`.

---

## Software Requirements

| Tool | Version |
|---|---|
| MATLAB | R2023a or later |
| Communications Toolbox | Required |
| DSP System Toolbox | Required |
| Communications Toolbox Support Package for ADALM-PLUTO | Required |
| Python | 3.9+ |
| PyTorch | 2.0+ |
| scipy | 1.10+ |
| numpy | 1.24+ |

### Python Environment Setup

```powershell
# Create and activate virtual environment
python -m venv venv
Set-ExecutionPolicy Unrestricted -Scope Process   # Windows only (once per session)
.\venv\Scripts\Activate.ps1

# Install dependencies
pip install torch scipy numpy matplotlib
```

---

## Repository Structure

```
OFDM/
├── config.m                        # ← SHARED config: edit this to keep TX/RX in sync
│
├── T/                              # Transmitter
│   ├── OFDMT.m                     # Main TX script — run this FIRST
│   ├── helperOFDMTx.m              # Per-frame OFDM modulator (grid → waveform)
│   ├── helperOFDMTxInit.m          # TX object initializer (filters, CRC, PN seq)
│   ├── helperOFDMSetParamsSDR.m    # Derives all system parameters from config
│   ├── helperOFDMSyncSignal.m      # Generates the Zadoff-Chu sync preamble
│   ├── helperOFDMRefSignal.m       # Generates the channel reference signal
│   ├── helperOFDMPilotSignal.m     # Generates pilot subcarrier values
│   └── helperOFDMFrontEndFilter.m  # Baseband TX filter coefficients
│
├── R/                              # Receiver
│   ├── OFDMR_Working.m             # Main RX script — run SECOND (after TX is up)
│   ├── helperOFDMRx.m              # Per-frame demodulator (waveform → bits + grid)
│   ├── helperOFDMRxFrontEnd.m      # Sample buffer manager (timing advance)
│   ├── helperOFDMRxSearch.m        # Sync search state machine (searching → camped)
│   ├── helperOFDMRxInit.m          # RX object initializer
│   ├── helperOFDMChannelEstimation.m # Pilot-based channel estimator
│   ├── helperOFDMFrequencyOffset.m # CFO estimator (cyclic prefix correlation)
│   ├── helperOFDMSetParamsSDR.m    # Mirror of TX params (must stay identical)
│   ├── tx_reference.mat            # Ground-truth TX data loaded by RX for K-Lock
│   ├── OFDM_Demodulated_Data.mat   # ← OUTPUT: paired TX/RX dataset
│   └── captures/                   # Timestamped archives of each run
│
├── create_pytorch_dataset.py       # Converts .mat → PyTorch .pth dataset
├── display_dataset.py              # Dataset inspection & plotting tool
├── plot_ofdm_grid.m                # MATLAB resource grid & constellation plotter
└── notes.txt                       # Lab notes
```

---

## Quick Start

### Step 1 — Configure
Edit `config.m` to set your desired parameters. Both TX and RX must use the same file:

```matlab
OFDMParams.FFTLength      = 128;     % FFT size
dataParams.modOrder       = 4;       % 4=QPSK, 16=16QAM, 64=64QAM
rxNumFrames               = 10000;   % Frames to capture
centerFrequency           = 9.15e8;  % 915 MHz
txWaitForRX               = true;    % TX waits for RX flag (recommended)
```

### Step 2 — Run the Transmitter
Open MATLAB, navigate to `T/`, and run:
```matlab
OFDMT
```
The TX will:
1. Generate **10,000 unique random-bit frames** (this takes ~30 seconds)
2. Save `tx_reference.mat` to `R/` so the RX can verify frame matches
3. Wait for the RX to create `rx_running.flag` before broadcasting

### Step 3 — Run the Receiver
In a **second MATLAB instance** (or separate session), navigate to `R/` and run:
```matlab
OFDMR_Working
```
The RX will:
1. Stream IQ samples straight into RAM (Stage 1)
2. Attempt K-Lock synchronization
3. Decode and verify each frame (Stage 2)
4. Save output to `OFDM_Demodulated_Data.mat`

### Step 4 — Convert to PyTorch
Once the RX finishes, activate your Python environment and run:
```powershell
cd C:\Users\<you>\Desktop\OFDM
.\venv\Scripts\Activate.ps1
python create_pytorch_dataset.py
```
Output: `data/ofdm_dataset_matlab.pth`

### Step 5 — Verify
```powershell
python display_dataset.py
```

---

## Configuration Reference

All parameters shared between TX and RX live **exclusively** in `config.m`.

| Parameter | Default | Description |
|---|---|---|
| `OFDMParams.FFTLength` | `128` | FFT size (64/128/256/512/1024/2048/4096) |
| `OFDMParams.CPLength` | `32` | Cyclic prefix length (samples) |
| `OFDMParams.NumSubcarriers` | `90` | Active data+pilot subcarriers |
| `OFDMParams.Subcarrierspacing` | `30e3` | Subcarrier spacing in Hz |
| `OFDMParams.PilotSubcarrierSpacing` | `9` | 1 pilot every N subcarriers |
| `dataParams.modOrder` | `4` | Modulation order (4=QPSK) |
| `dataParams.coderate` | `'1/2'` | Convolutional code rate |
| `dataParams.numSymPerFrame` | `25` | OFDM symbols per frame |
| `centerFrequency` | `9.15e8` | RF center frequency (Hz) |
| `txNumFrames` | `10000` | Number of unique TX frames to generate |
| `rxNumFrames` | `10000` | Number of frames RX will capture |
| `txWaitForRX` | `true` | TX waits for RX flag before transmitting |
| `loopbackMode` | `false` | `true` = software loopback (no hardware needed) |
| `loopbackSNR_dB` | `25` | AWGN level for loopback testing |

---

## Architecture Deep Dive

### Frame Structure

Each OFDM frame contains `numSymPerFrame = 25` symbols arranged as:

```
Symbol Index:  1          2          3          4 ... 25
               ┌──────────┬──────────┬──────────┬──────────┐
               │   SYNC   │   REF    │  HEADER  │   DATA   │  ← (22 data symbols)
               │(Zadoff-  │(channel  │(FFT+MOD+ │(payload  │
               │  Chu)    │  est.)   │ CodeRate │  + pilot │
               │          │          │ +SeqID)  │  subcar.)│
               └──────────┴──────────┴──────────┴──────────┘
     Subcarriers:   62         90         72          80
```

**Header bits (14 bits + 6-bit SeqID = 20 bits total, before CRC/coding):**

| Field | Bits | Description |
|---|---|---|
| FFT Length Index | 3 | Maps 64→0, 128→1, 256→2 … |
| Modulation Type | 3 | BPSK→0, QPSK→1, 16QAM→2 … |
| Code Rate Index | 2 | 1/2→0, 2/3→1, 3/4→2, 5/6→3 |
| **Frame Sequence ID** | **6** | **`mod(frameIdx-1, 64)` — wraps 0→63** |

The 6-bit SeqID is the core sync word. It lets the RX identify the frame within a 64-frame window; the K-Lock resolves it to an absolute index in 1–10,000.

---

### Transmitter Pipeline

```
config.m
   │
   ▼
helperOFDMSetParamsSDR   →  sysParam (FFT, CP, subcarriers, trBlkSize, etc.)
   │
   ▼
Frame generation loop (seqIdx = 1:10000)
   │  txParam.txDataBits  = randi([0 1], trBlkSize, 1)  ← unique random bits
   │  txParam.frameSeqNum = mod(seqIdx-1, 64)           ← 6-bit wrapped ID
   │
   ▼
helperOFDMTx (per frame)
   ├── Sync symbol      → Zadoff-Chu sequence (62 subcarriers)
   ├── Reference symbol → Known pilots for channel estimation (90 subcarriers)
   ├── Header symbol    → [FFT|MOD|CR|SeqID] + CRC16 + conv(5,7) + BPSK
   └── Data symbols     → bits → CRC → scramble → conv encode → interleave → QAM → OFDM
   │
   ▼
txWaveform (concatenated, up to 10,000 × txOutSize samples)
   │
   ▼
Save allTxBits{}, allTxGrids{} → R/tx_reference.mat   ← ground truth for RX
   │
   ▼
PlutoSDR TX  →  broadcasts chunks in a loop until rx_running.flag disappears
```

---

### Receiver Pipeline

The RX uses a **two-stage architecture** to decouple hardware streaming from processing:

#### Stage 1 — Hardware Capture (Real-Time)

```
PlutoSDR RX hardware
   │  (continuous IQ streaming)
   ▼
helperOFDMRxFrontEnd    ← manages persistent signalBuffer + timing advance
   │
   ▼
signalBuffer (RAM)      ← one frame's worth of IQ at a time
   │
   ▼
helperOFDMRxSearch      ← sync symbol detection (Zadoff-Chu cross-correlation)
   │  State: SEARCHING → CAMPED (once sync symbol found)
   ▼
helperOFDMFrequencyOffset  ← CFO estimation via cyclic prefix correlation
   │
   ▼
helperOFDMRx            ← full frame demodulation:
   ├── Channel estimation  (helperOFDMChannelEstimation via reference symbol)
   ├── OFDM demodulation   (ofdmdemod)
   ├── Channel equalization (freq-domain division)
   ├── Pilot removal
   ├── QAM demodulation
   ├── De-interleave
   ├── Viterbi decode
   ├── De-scramble
   ├── CRC check           → headerCRCPass / dataCRCPass flags
   └── rxDataBits, rxDiagnostics (frameSeqNum, SNR, raw grid, EQ data)
```

#### Stage 2 — Offline Decode & Matching

Once a frame is demodulated, it is matched to ground truth:

```
rxDataBits + rxDiagnostics.frameSeqNum
   │
   ▼
Header CRC passed?
   ├── YES → update globalSeqIdx via delta unwrap
   └── NO  → globalSeqIdx += 1 (safe fallback)
   │
   ▼
isSynced?
   ├── YES → mappedIndex = mod(globalSeqIdx-1, 10000) + 1
   │          groundTruth = allTxBits{mappedIndex}
   └── NO  → K-Lock search (test all 64-period candidates, pick lowest BER)
              → LOCK confirmed if best BER < 0.40
   │
   ▼
BER = mean(xor(groundTruthBits, rxDataBits))
   │
   ▼
Save to demodulatedData struct array → OFDM_Demodulated_Data.mat
```

---

### TX/RX Frame Matching (K-Lock)

The K-Lock is the core innovation that makes ground-truth pairing possible without a shared clock.

**The Problem:** The 6-bit header SeqID wraps every 64 frames. When the RX sees `seqID=40`, the actual TX frame could be 40, 104, 168, 232... (any of the ~156 candidates in a 10,000-frame set).

**The Solution:** Test all candidates against the live decoded bits using BER:

```
seqID = 40  →  candidates: [40, 104, 168, 232, ..., 9960 + 40]
                                                ( = baseSeq + k×64 )

For each candidate k:
    BER = compare(allTxBits{candidate_k}, rxDataBits)

Results:
    k=0  →  BER = 0.501  (wrong frame, random noise)
    k=1  →  BER = 0.497  (wrong frame)
    ...
    k=2  →  BER = 0.002  ← MATCH FOUND  (correct frame!)
    ...
    k=156 → BER = 0.499

LOCK: globalSeqIdx = 40 + 2×64 = 168  →  TX Frame #168
```

After K-Lock, subsequent frames are tracked by simple +1 delta (or +delta from header SeqID), so the expensive search runs **only once per session** (or once after each auto-recovery reset).

---

### Auto-Recovery Mechanisms

The receiver implements three safety nets to handle real-world hardware issues:

#### 1. GAP FIX — TX Loop Boundary Glitch
When the TX loops around from frame 10,000 back to frame 1, a momentary gap in the IQ stream causes the header CRC to fail.

**Trigger:** ≥3 consecutive `headerCRCErrorFlag = true`
**Action:** Clears all persistent functions (including `helperOFDMRxFrontEnd` to flush the corrupted buffer), resets sync state, and triggers a full re-lock.

#### 2. SYNC DRIFT MONITOR — Phase/Timing Drift
If the RX frame timing drifts by ≥1 frame relative to the TX (e.g., due to SDR buffer underrun), BER will rise to ~0.50 on all frames.

**Trigger:** ≥5 consecutive frames with BER > 0.45
**Action:** Clears all physical tracking state, forces full hardware re-sync and K-Lock re-acquisition.

#### 3. K-Lock GUARD — Pure Noise Rejection
If the K-Lock cannot find any candidate with BER < 0.40 (meaning the frame is pure noise, not a real OFDM payload), the frame is discarded silently.

**Trigger:** All K candidates have BER > 0.40
**Action:** `continue` — skip this frame, no data saved, try next.

---

## Dataset Format

### MATLAB Output — `R/OFDM_Demodulated_Data.mat`

A struct array `demodulatedData` with one entry per successfully captured frame:

| Field | Type | Shape | Description |
|---|---|---|---|
| `Frame` | int | scalar | RX capture index (1–10000) |
| `MappedTxFrame` | int | scalar | Absolute TX frame index matched by K-Lock |
| `FrameSeqID` | int | scalar | Raw 6-bit header ID (0–63), or -1 if CRC failed |
| `RawGrid` | complex | 80×24 | Received resource grid (data subcarriers × data symbols) |
| `TxGrid` | complex | 90×25 | Transmitted resource grid (all subcarriers × all symbols) |
| `TxBits` | uint8 | 1722×1 | Ground-truth TX bits for this frame |
| `RawBits` | uint8 | 1722×1 | Decoded RX bits |
| `EqData` | complex | 80×22 | Equalized constellation points |
| `TxRxCompare` | uint8 | 1722×2 | [TxBit, RxBit] columns for per-bit comparison |
| `BER` | double | scalar | Bit Error Rate vs. ground truth |
| `SNR_dB` | double | scalar | Estimated SNR from pilot comparison |
| `headerCRCPass` | logical | scalar | `true` if header CRC matched |
| `dataCRCPass` | logical | scalar | `true` if data CRC matched |
| `Message` | char | string | Decoded ASCII message (if printable) |
| `Timestamp` | char | string | Capture wallclock time |

### PyTorch Output — `data/ofdm_dataset_matlab.pth`

A `CustomDataset` object loadable with `torch.load()`:

```python
dataset = torch.load('data/ofdm_dataset_matlab.pth')
rx_iq, tx_iq, tx_bits, snr = dataset[i]

# rx_iq   : torch.complex64  shape [24, 80]  — received IQ (symbols × subcarriers)
# tx_iq   : torch.complex64  shape [25, 90]  — transmitted IQ (symbols × subcarriers)
# tx_bits : torch.float32    shape [1722]    — ground-truth bit labels
# snr     : float            scalar          — estimated SNR in dB
```

> **Note on dimensions:** MATLAB stores grids as `[subcarriers × symbols]`. The Python loader transposes to `[symbols × subcarriers]` to match standard PyTorch `(batch, time, freq)` convention.

---

## Visualization & Diagnostics

### MATLAB — Resource Grid & Constellation

```matlab
% From OFDM/ root directory:
plot_ofdm_grid    % set frameIndex on line 35 to choose which frame to inspect
```

Produces three figures:
- **Figure 1:** TX clean grid vs. RX received grid vs. |TX−RX| error grid
- **Figure 2:** TX constellation, RX constellation (post-EQ), bit error heatmap
- **Figure 3:** Per-frame BER and SNR over the full capture

### Python — Dataset Inspection

```powershell
python display_dataset.py
```

Prints frame shape, sample values, and saves `data/sample_rx_tx_grid_plot.png` showing the RX and TX resource grids side by side.

---

## Known Limitations

| Limitation | Detail |
|---|---|
| ~100 frame startup gap | RX spends ~100 TX frame durations on AGC drain and calibration before K-Lock; the dataset starts at TX frame ~100, not frame 1. |
| 6-bit SeqID cap | K-Lock can resolve up to 10,000 frames, but if more than 32 frames are dropped in a single gap, the delta-unwrap may mistrack by one period (64 frames). |
| PlutoSDR underruns | The PlutoSDR USB driver occasionally drops samples during heavy CPU load. This triggers auto-recovery but may produce ~20 high-BER frames per gap. |
| Single-antenna SISO | The current implementation is SISO only. MIMO would require synchronized multi-channel capture hardware. |
| No Doppler compensation | CFO is estimated once per frame using cyclic prefix correlation. Fast-moving channels would require per-symbol tracking. |

---

## Troubleshooting

### "Skipping unresolvable frame (all K candidates BER>0.40)"
The K-Lock cannot find a valid match. Likely causes:
- TX and RX are not running simultaneously (TX finished before RX started)
- `tx_reference.mat` in `R/` is stale — re-run `OFDMT.m` to regenerate it
- SNR is too low — reduce the distance between antennas or increase TX gain

### "All BER values are ~0.50"
The RX is decoding but matching against the wrong TX frames. Causes:
- `tx_reference.mat` was generated in a different session from the current RX capture
- `globalSeqIdx` tracking drifted after a hardware underrun — the Sync Drift Monitor will auto-correct after 5 bad frames

### Low Avg Match Rate in summary printout
Check if the BER calculation is filtering out 0.00 BER frames. The correct calculation uses `[demodulatedData(1:dataIdx-1).BER]` (includes zero-BER frames). The old `BER(BER~=0)` filter was incorrect and would report ~51% even on a perfect run.

### PlutoSDR not found
```matlab
findPlutoRadio   % lists all connected Plutos and their serial numbers
```
Update `targetSerialTx` in `OFDMT.m` and `targetSerialRx` in `OFDMR_Working.m` to match.

### PowerShell execution policy error
```powershell
Set-ExecutionPolicy Unrestricted -Scope Process
```
This only affects the current terminal session and requires no admin privileges.
