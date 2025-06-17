#!/bin/bash
set -e
# Activer la capture des erreurs
trap 'echo "Erreur détectée. Arrêt du script." >&2; exit 1' ERR

echo "=== Script de récupération Kali Linux Dual-Boot ==="

# 1. Détection du mode (UEFI ou BIOS)
if [ -d /sys/firmware/efi ]; then
    echo "[INFO] Mode de démarrage : UEFI"
    EFI=true
else
    echo "[INFO] Mode de démarrage : Legacy BIOS"
    EFI=false
fi

# 2. Identification de la partition racine Kali
echo "[INFO] Détection de la partition racine de Kali Linux..."
ROOT_PART=""
# Lister les partitions de type 'part' (lsblk inclus les noms complets)
for part in $(lsblk -lpno NAME,TYPE | awk '$2=="part" {print $1}'); do
    # Essayer de monter en lecture seule
    echo "  - Test de la partition $part..."
    mkdir -p /mnt/tmproot
    if mount -o ro "$part" /mnt/tmproot 2>/dev/null; then
        if [ -f /mnt/tmproot/etc/os-release ]; then
            if grep -qi "ID=kali" /mnt/tmproot/etc/os-release \
               || grep -qi "Kali GNU/Linux" /mnt/tmproot/etc/os-release; then
                ROOT_PART="$part"
                echo "[INFO] Partition Kali trouvée: $ROOT_PART"
                umount /mnt/tmproot
                rmdir /mnt/tmproot
                break
            fi
        fi
        umount /mnt/tmproot
    fi
    rmdir /mnt/tmproot 2>/dev/null || true
done

if [ -z "$ROOT_PART" ]; then
    echo "[ERROR] Partition racine de Kali non trouvée. Vérifiez vos disques." >&2
    exit 1
fi

# 3. Montage de la racine et préparation du chroot
echo "[INFO] Montage de la partition Kali ($ROOT_PART) sur /mnt"
mount "$ROOT_PART" /mnt

# Créer le fichier de log sur la partition Kali
LOGFILE="/mnt/root/recovery_diagnostic.log"
touch "$LOGFILE"
echo "[INFO] Démarrage du journal de diagnostic." | tee -a "$LOGFILE"

echo "[INFO] Montage des systèmes de fichiers virtuels pour chroot..."
mkdir -p /mnt/{dev,proc,sys}
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

# Si UEFI, monter aussi efivars
if $EFI; then
    echo "[INFO] Mode UEFI détecté : montage des EFI variables"
    mkdir -p /mnt/sys/firmware/efi/efivars
    mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars

    # Détection de la partition EFI (FAT32)
    echo "[INFO] Recherche de la partition EFI..."
    EFI_PART=""
    ROOT_DISK=$(echo "$ROOT_PART" | sed -r 's/p?[0-9]+$//')
    # Parcourir les partitions du disque racine
    for part in $(lsblk -lnpo NAME "${ROOT_DISK}"* | grep -v "${ROOT_DISK}$"); do
        # Vérifier le type de système de fichiers
        FS_TYPE=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "")
        if [ "$FS_TYPE" = "vfat" ] || [ "$FS_TYPE" = "FAT32" ]; then
            EFI_PART="$part"
            echo "[INFO] Partition EFI détectée: $EFI_PART"
            break
        fi
    done
    if [ -n "$EFI_PART" ]; then
        mkdir -p /mnt/boot/efi
        mount "$EFI_PART" /mnt/boot/efi
        echo "[INFO] Partition EFI montée sur /mnt/boot/efi"
    else
        echo "[WARN] Partition EFI introuvable. Le montage EFI sera ignoré."
    fi
fi

# 4. Chroot dans la partition Kali
echo "[INFO] Entrée dans le chroot de Kali..."
chroot /mnt /bin/bash << 'EOF'
set -e
# Dans le chroot : réinstaller GRUB et mettre à jour l'initramfs
echo "[CHROOT] Réinstallation de GRUB sur le disque principal..."
# Extraire le nom du disque racine (ex: /dev/sda ou /dev/nvme0n1)
ROOT_DISK=$(findmnt -n -o SOURCE / | sed -r 's/p?[0-9]+$//')
grub-install --recheck "$ROOT_DISK"
echo "[CHROOT] GRUB installé sur $ROOT_DISK"
echo "[CHROOT] Reconstruction de l'initramfs..."
update-initramfs -u -k all
echo "[CHROOT] Initramfs mis à jour."

# 5. Modification des options GRUB si carte NVIDIA détectée (ajout de nomodeset)
if lspci | grep -qi nvidia; then
    echo "[CHROOT] Carte graphique NVIDIA détectée."
    echo "[CHROOT] Ajout de 'nomodeset' aux options GRUB..."
    GRUB_FILE="/etc/default/grub"
    if ! grep -q "nomodeset" "$GRUB_FILE"; then
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=".*"/\1 nomodeset"/' "$GRUB_FILE"
        echo "[CHROOT] 'nomodeset' ajouté dans $GRUB_FILE"
    else
        echo "[CHROOT] 'nomodeset' déjà présent dans $GRUB_FILE"
    fi
else
    echo "[CHROOT] Pas de carte NVIDIA détectée, étape 'nomodeset' ignorée."
fi

# 6. Proposer l'installation des pilotes NVIDIA
echo "[CHROOT] Vérification de l'installation des pilotes NVIDIA..."
if lspci | grep -qi nvidia; then
    read -p "[CHROOT] Installer les pilotes NVIDIA propriétaires ? (o/N) : " rep
    if [[ "$rep" =~ ^[oO] ]]; then
        echo "[CHROOT] Installation des pilotes NVIDIA via apt..."
        apt update
        apt install -y nvidia-driver
    else
        echo "[CHROOT] Installation des pilotes NVIDIA sautée."
    fi
fi

# 7. Mise à jour finale du GRUB
echo "[CHROOT] Mise à jour finale de GRUB..."
update-grub
echo "[CHROOT] GRUB configuré."

EOF
echo "[INFO] Sortie du chroot."

# 8. Démontage des systèmes de fichiers
echo "[INFO] Démontage des systèmes de fichiers montés..."
umount -l /mnt/proc || true
umount -l /mnt/sys || true
umount -l /mnt/dev || true
if $EFI && [ -n "$EFI_PART" ]; then
    umount -l /mnt/boot/efi || true
fi
echo "[INFO] Nettoyage terminé."

# 9. Proposer un redémarrage
echo "[INFO] Terminé. Vous pouvez consulter le rapport dans $LOGFILE"
read -p "Redémarrer maintenant le système ? (o/N) : " answer
if [[ "$answer" =~ ^[oO] ]]; then
    echo "[INFO] Redémarrage en cours..."
    reboot
else
    echo "[INFO] Veuillez redémarrer manuellement plus tard."
fi

exit 0
