sudo pacman -S --needed - < packages.x86_64
sudo systemctl enable bluetooth --now

git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si
cd ...
./reinstall_aur.sh
