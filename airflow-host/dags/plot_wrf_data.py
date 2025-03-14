import xarray as xr
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import glob
import os

import sys
# User input: path to the wrf-output directory
wrf_output_dir = sys.argv[1]
save_plot_dir = os.path.dirname(wrf_output_dir)

# Get the first .nc file in the wrf_output_dir
nc_file = glob.glob(os.path.join(wrf_output_dir, "*.nc"))[0]

ds = xr.open_dataset(nc_file)
# Print dataset information
print(ds)

# Check for available temperature variables
print([var for var in ds.variables if 'T' in var])

# Extract variables for 2-meter temperature plot
T2 = ds["T2"].isel(Time=0)  # Select the first time step
lats = ds["XLAT"].isel(Time=0)
lons = ds["XLONG"].isel(Time=0)

# Plot 2-Meter Temperature and save it as a PNG file
plt.figure(figsize=(10, 6))
plt.contourf(lons, lats, T2, cmap="coolwarm")
plt.colorbar(label="Temperature (K)")
plt.xlabel("Longitude")
plt.ylabel("Latitude")
plt.title("2m Temperature")
plt.savefig(os.path.join(save_plot_dir, "2m_temperature.png"))  # Save plot to file
plt.close()

# List of WRF output files for animation
files = sorted(glob.glob(os.path.join(wrf_output_dir, 'wrfout_d01_*.nc')))

# Prepare figure for animation
fig, ax = plt.subplots(figsize=(10, 6))

# Open the first WRF file to create the initial colorbar
ds = xr.open_dataset(files[0])
T2 = ds["T2"].isel(Time=0)  # Select first time step
lats = ds["XLAT"].isel(Time=0)
lons = ds["XLONG"].isel(Time=0)

# Create initial contour plot to set color range
contour = ax.contourf(lons, lats, T2, cmap="coolwarm")

# Add colorbar once (this prevents the multiple colorbar issue)
cbar = fig.colorbar(contour, ax=ax, label="Temperature (K)")

def animate(i):
    # Open the current WRF file
    ds = xr.open_dataset(files[i])
    
    # Extract data for temperature, lat, lon, and time
    T2 = ds["T2"].isel(Time=0)  # Select first time step
    lats = ds["XLAT"].isel(Time=0)
    lons = ds["XLONG"].isel(Time=0)
    
    # Clear previous plot (except colorbar)
    ax.clear()
    
    # Recreate the contour plot for the new temperature data
    contour = ax.contourf(lons, lats, T2, cmap="coolwarm")
    ax.set_xlabel("Longitude")
    ax.set_ylabel("Latitude")
    ax.set_title(f"2m Temperature - Time: {ds.XTIME.values[0]}")
    
    # Update the colorbar with the latest data (if needed)
    cbar.update_ticks()

    # Return the contour object to update the plot
    return contour #.collections

# Create the animation
ani = animation.FuncAnimation(fig, animate, frames=len(files), interval=1000, blit=False)

# Save the animation to a file (e.g., an mp4 file)
ani.save(os.path.join(save_plot_dir, "temperature_animation.mp4"), writer="ffmpeg", dpi=300)

# Close the figure after the animation
plt.close()
