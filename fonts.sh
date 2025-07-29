#!/bin/bash

# This script automates the "Newest" section of the Arch Linux Font Improvement Guide.
# It will install recommended fonts, enable font presets, configure FreeType,
# and set up font consistency via /etc/fonts/local.conf.

echo "Starting Arch Linux Font Improvement Script..."

# 1. Install recommended fonts
echo "Installing core fonts: ttf-dejavu, ttf-liberation, noto-fonts..."
sudo pacman -S --noconfirm ttf-dejavu ttf-liberation noto-fonts

# 2. Enable font presets by creating symbolic links
# Using -f to force overwrite if links already exist
# Updated path from /etc/fonts/conf.avail/ to /usr/share/fontconfig/conf.avail/ as per Gist comments
echo "Enabling font presets..."
sudo ln -sf /usr/share/fontconfig/conf.avail/70-no-bitmaps.conf /etc/fonts/conf.d/
sudo ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/
sudo ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/

# 3. Enable FreeType subpixel hinting mode
echo "Configuring FreeType subpixel hinting mode..."
# Uncomment the desired mode in /etc/profile.d/freetype2.sh
sudo sed -i 's/^#export FREETYPE_PROPERTIES="truetype:interpreter-version=40"/export FREETYPE_PROPERTIES="truetype:interpreter-version=40"/' /etc/profile.d/freetype2.sh

# 4. Create /etc/fonts/local.conf for font consistency
echo "Creating /etc/fonts/local.conf for font consistency..."
sudo tee /etc/fonts/local.conf > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
    <match>
        <edit mode="prepend" name="family">
            <string>Noto Sans</string>
        </edit>
    </match>
    <match target="pattern">
        <test qual="any" name="family">
            <string>serif</string>
        </test>
        <edit name="family" mode="assign" binding="same">
            <string>Noto Serif</string>
        </edit>
    </match>
    <match target="pattern">
        <test qual="any" name="family">
            <string>sans-serif</string>
        </test>
        <edit name="family" mode="assign" binding="same">
            <string>Noto Sans</string>
        </edit>
    </match>
    <match target="pattern">
        <test qual="any" name="family">
            <string>monospace</string>
        </test>
        <edit name="family" mode="assign" binding="same">
            <string>Noto Mono</string>
        </edit>
    </match>
</fontconfig>
EOF

echo "Font improvement script completed."
echo "You may need to reboot your system or log out and back in for all changes to take effect."
echo ""
echo "Additional recommended fonts from the guide (install manually if desired, some require AUR helper):"
echo "Caladea (ttf-caladea), Carlito (ttf-carlito), Impallari Cantora (aur/ttf-impallari-cantora),"
echo "Open Sans (ttf-opensans), Overpass (otf-overpass), Roboto (ttf-roboto),"
echo "TeX Gyre (tex-gyre-fonts), Ubuntu (ttf-ubuntu-font-family),"
echo "Courier Prime (aur/ttf-courier-prime), Gelasio (aur/ttf-gelasio-ib),"
echo "Merriweather (aur/ttf-merriweather), Source Sans Pro (aur/ttf-source-sans-pro-ibx),"
echo "Signika (aur/ttf-signika)"
