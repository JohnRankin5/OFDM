import os
import scipy.io
import torch
from torch.utils.data import Dataset
import numpy as np

# We modify CustomDataset to contain everything: the raw RX grid, the perfect TX grid, and the original bits
class CustomDataset(Dataset):
    def __init__(self):
        self.rx_iq = []    # Raw Received IQ Sequence (with noise and channel distortion)
        self.tx_iq = []    # Perfect Transmitted IQ Sequence (Clean, from TX)
        self.tx_bits = []  # Original transmitted bitstream labels
        self.sinr = []     # Calculated SNR in dB

    def __len__(self):
        return len(self.rx_iq)
    
    def __getitem__(self, index):
        # We can extract all 4 elements
        return self.rx_iq[index], self.tx_iq[index], self.tx_bits[index], self.sinr[index]
    
    def add_item(self, rx_grid, tx_grid, tx_bits, sinr):
        self.rx_iq.append(rx_grid) 
        self.tx_iq.append(tx_grid) 
        self.tx_bits.append(tx_bits) 
        self.sinr.append(sinr) 

def main():
    dataset = CustomDataset()
    mat_path = 'R/OFDM_Demodulated_Data.mat'
    
    if not os.path.exists(mat_path):
        print(f"Error: {mat_path} not found. Please run the MATLAB Receiver first.")
        return

    print(f"Loading {mat_path}...")
    # simplify_cells=True converts MATLAB structs to generic Python dictionaries cleanly
    mat = scipy.io.loadmat(mat_path, simplify_cells=True)
    
    if 'demodulatedData' not in mat:
        print("Error: 'demodulatedData' array not found in the .mat file.")
        return
        
    demod_data = mat['demodulatedData']

    # If only 1 frame was saved, scipy might not load it as a list
    if isinstance(demod_data, dict):
        demod_data = [demod_data]
    elif not isinstance(demod_data, (list, np.ndarray)):
        print("No valid frames to process.")
        return

    added_count = 0
    for i, frame in enumerate(demod_data):
        try:
            # Extract
            raw_grid = frame.get('RawGrid', None)   # Received Complex 2D array (subcarriers, symbols)
            tx_grid = frame.get('TxGrid', None)     # Transmitted Complex 2D array
            tx_bits = frame.get('TxBits', None)     # Binary 1D array
            snr_db = frame.get('SNR_dB', np.nan)    # Scalar

            if raw_grid is None or tx_grid is None:
                continue
            
            # The reference NN expects shape (symbols, subcarriers)
            # MATLAB produces shape [90, 25] (subcarriers x symbols).
            # We transpose it to match the standard (time, freq) / (symbols, subcarriers) layout
            rx_iq_tensor = torch.tensor(raw_grid.T, dtype=torch.complex64)
            tx_iq_tensor = torch.tensor(tx_grid.T, dtype=torch.complex64)
            bits_tensor = torch.tensor(tx_bits, dtype=torch.float32)

            # Skip data with completely NaN SNR
            if not np.isnan(snr_db):
                dataset.add_item(rx_iq_tensor, tx_iq_tensor, bits_tensor, float(snr_db))
                added_count += 1
                
        except Exception as e:
            print(f"Skipped frame {i} due to Error: {e}")

    os.makedirs('data', exist_ok=True)
    out_file = 'data/ofdm_dataset_matlab.pth'
    torch.save(dataset, out_file)
    print(f"\nSuccess! Added {added_count} completely matched random TX/RX frames to the dataset.")
    print(f"Dataset securely saved as: {out_file}")
    print("This file contains the perfectly paired TX IQ matrix and RX IQ matrix for each frame!")

if __name__ == '__main__':
    main()
