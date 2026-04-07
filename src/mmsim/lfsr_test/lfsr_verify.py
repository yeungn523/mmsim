import numpy as np
import matplotlib.pyplot as plt
import os
import csv

SEED  = 0xDEADBEEF
POLY  = 0xB4BCD35C

def galois_lfsr(state, poly=POLY):
    lsb = state & 1
    state >>= 1
    if lsb:
        state ^= poly
    return state & 0xFFFFFFFF

# Print first 8 values — paste into tb_galois_lfsr expected[]
print("First 8 LFSR values (paste into Test 10 expected[]):")
state = SEED
for i in range(8):
    state = galois_lfsr(state)
    print(f"  expected[{i}] = 32'h{state:08X};")

# Statistical check and visualization on CSV if it exists
if os.path.exists("lfsr_samples.csv"):
    values = []
    with open("lfsr_samples.csv") as f:
        reader = csv.DictReader(f)
        for row in reader:
            values.append(int(row['value']))

    print(f"\nCross-check: {len(values)} samples from ModelSim CSV")

    # Bit uniformity
    total_bits = len(values) * 32
    ones = sum(bin(v & 0xFFFFFFFF).count('1') for v in values)
    ratio = ones / total_bits
    print(f"  Ones ratio:    {ratio:.5f}  (ideal 0.50000)")
    print(f"  Uniformity:    {'PASS' if 0.49 < ratio < 0.51 else 'FAIL'}")

    # Check for zeros
    zeros = sum(1 for v in values if v == 0)
    print(f"  Zero states:   {zeros}  (should be 0)")

    # Sequence match vs Python golden
    state = SEED
    py_seq = []
    for _ in range(len(values)):
        state = galois_lfsr(state)
        py_seq.append(state)

    mismatches = sum(1 for a, b in zip(values, py_seq) if a != b)
    print(f"  Sequence match: {len(values) - mismatches}/{len(values)} correct")
    print(f"  Result:         {'PASS' if mismatches == 0 else f'FAIL ({mismatches} mismatches)'}")

    # ---------------------------------------------------------
    # Matplotlib Visualization: Uniform Distribution Histogram
    # ---------------------------------------------------------
    print("\nGenerating Uniform Distribution Histogram...")
    
    num_bins = 100
    expected_count = len(values) / num_bins

    plt.figure(figsize=(10, 6))
    
    # Plot histogram
    counts, bins, patches = plt.hist(
        values, 
        bins=num_bins, 
        range=(0, 0xFFFFFFFF), 
        color='#4C72B0', 
        edgecolor='black', 
        linewidth=0.5,
        alpha=0.8
    )
    
    # Add ideal uniform line
    plt.axhline(
        expected_count, 
        color='#C44E52', 
        linestyle='--', 
        linewidth=2, 
        label=f'Ideal Uniform Count ({expected_count:,.0f})'
    )
    
    # Formatting
    plt.title('Galois LFSR Output Distribution (100,000 Samples)', fontsize=14, pad=15)
    plt.xlabel('32-bit Output Value', fontsize=12)
    plt.ylabel('Frequency', fontsize=12)
    
    # Format x-axis ticks to show scientific notation for 32-bit range clarity
    plt.ticklabel_format(style='sci', axis='x', scilimits=(0,0))
    plt.xlim(0, 0xFFFFFFFF)
    
    plt.legend(fontsize=11)
    plt.grid(axis='y', linestyle='--', alpha=0.7)
    
    # Tight layout to remove excess whitespace
    plt.tight_layout()
    
    # Save the plot for the lab report
    report_image_filename = 'lfsr_uniform_distribution.png'
    plt.savefig(report_image_filename, dpi=300)
    print(f"Saved high-res plot for lab report as: '{report_image_filename}'")
    
    # Display the plot window
    plt.show()

else:
    print("\nlfsr_samples.csv not found — run ModelSim first")