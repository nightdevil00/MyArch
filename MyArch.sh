sudo pacman -S --needed - < packages.x86_64
sudo systemctl enable bluetooth --now

sudo git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
sudo makepkg -si
cd ...
./reinstall_aur.sh
