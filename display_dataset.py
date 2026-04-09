import torch
import matplotlib.pyplot as plt

# We need the class definition available to load the dataset
from create_pytorch_dataset import CustomDataset

def main():
    dataset_path = 'data/ofdm_dataset_matlab.pth'
    
    try:
        dataset = torch.load(dataset_path)
    except FileNotFoundError:
        print(f"Dataset not found at {dataset_path}. Please run create_pytorch_dataset.py first.")
        return

    print(f"Successfully loaded dataset with {len(dataset)} perfectly matched frames!\n")

    # Get the very first paired item in the dataset
    rx_iq_tensor, tx_iq_tensor, tx_bits_tensor, snr = dataset[0]

    print("=== SYNCHRONIZED FRAME 0 ===")
    print(f"1. RX IQ Matrix (Noisy Received)  : {rx_iq_tensor.shape} (symbols x subcarriers)")
    print(f"2. TX IQ Matrix (Clean Transmitted) : {tx_iq_tensor.shape} (symbols x subcarriers)")
    print(f"3. TX Data Bits (Ground Truth Labels): {tx_bits_tensor.shape} (flat binary array)")
    print(f"4. Signal-to-Noise (SNR)          : {snr:.2f} dB\n")

    print("--- SAMPLE OF RX IQ GRID (First symbol, 5 subcarriers) ---")
    print(rx_iq_tensor[0, :5].tolist())
    print("\n--- SAMPLE OF TX IQ GRID (First symbol, 5 subcarriers) ---")
    print(tx_iq_tensor[0, :5].tolist())

    # Optional: Plot the magnitude of the Rx and Tx Grid for the first frame side-by-side
    try:
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))
        
        im1 = ax1.imshow(torch.abs(rx_iq_tensor).numpy().T, aspect='auto', cmap='viridis')
        ax1.set_title(f"RX Raw Resource Grid (SNR: {snr:.2f} dB)")
        ax1.set_xlabel("OFDM Symbol")
        ax1.set_ylabel("Subcarrier")
        fig.colorbar(im1, ax=ax1, label="Magnitude")
        
        im2 = ax2.imshow(torch.abs(tx_iq_tensor).numpy().T, aspect='auto', cmap='viridis')
        ax2.set_title("TX Original Resource Grid (Clean)")
        ax2.set_xlabel("OFDM Symbol")
        ax2.set_ylabel("Subcarrier")
        fig.colorbar(im2, ax=ax2, label="Magnitude")
        
        plt.tight_layout()
        plt.savefig("data/sample_rx_tx_grid_plot.png")
        print("\nPlot saved successfully as 'data/sample_rx_tx_grid_plot.png'!")
    except Exception as e:
        print(f"\nCould not generate plot: {e}")

if __name__ == "__main__":
    main()
