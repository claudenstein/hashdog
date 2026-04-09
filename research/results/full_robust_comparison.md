# Full Hash-Mode Comparison: hashcat v7.1.2 vs hashdog

**System:** RTX 3090, CUDA 13.1, driver 590.48.01
**Methodology:** `-b` benchmark mode, 6s runtime, median of 3 runs, autotune cache cleared between runs
**Date:** 2026-04-09
**Modes tested:** 108 (the default benchmark set from `src/benchmark.c`)


#### Raw Hash

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 0 | MD5 | 67.19 GH/s | 66.98 GH/s | -0.3% |
| 100 | SHA1 | 24.24 GH/s | 24.16 GH/s | -0.3% |
| 600 | BLAKE2b-512 | 5.30 GH/s | 5.32 GH/s | +0.4% |
| 900 | MD4 | 119.38 GH/s | 120.71 GH/s | **+1.1%** |
| 1400 | SHA2-256 | 9.05 GH/s | 9.06 GH/s | +0.1% |
| 1700 | SHA2-512 | 3.10 GH/s | 3.11 GH/s | +0.1% |
| 5100 | Half MD5 | 43.47 GH/s | 44.03 GH/s | **+1.3%** |
| 11700 | GOST R 34.11-2012 (Streebog) 256-bit, big-endian | 201.68 MH/s | 206.55 MH/s | **+2.4%** |
| 11800 | GOST R 34.11-2012 (Streebog) 512-bit, big-endian | 206.47 MH/s | 201.08 MH/s | -2.6% |
| 17400 | SHA3-256 | 2.02 GH/s | 2.05 GH/s | **+1.4%** |
| 17600 | SHA3-512 | 2.02 GH/s | 2.02 GH/s | -0.2% |
| 31000 | BLAKE2s-256 | 13.33 GH/s | 13.33 GH/s | -0.0% |
| 31100 | ShangMi 3 (SM3) | 7.69 GH/s | 7.64 GH/s | -0.6% |

#### Raw Hash salted and/or iterated

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 10 | md5($pass.$salt) | 69.00 GH/s | 67.65 GH/s | -2.0% |
| 20 | md5($salt.$pass) | 34.75 GH/s | 34.51 GH/s | -0.7% |
| 110 | sha1($pass.$salt) | 24.20 GH/s | 24.48 GH/s | **+1.2%** |
| 120 | sha1($salt.$pass) | 16.89 GH/s | 16.88 GH/s | -0.1% |
| 1410 | sha256($pass.$salt) | 9.11 GH/s | 8.93 GH/s | -2.0% |
| 1420 | sha256($salt.$pass) | 8.09 GH/s | 8.19 GH/s | **+1.3%** |
| 1710 | sha512($pass.$salt) | 3.11 GH/s | 3.11 GH/s | +0.2% |
| 1720 | sha512($salt.$pass) | 2.90 GH/s | 2.92 GH/s | +0.7% |
| 10810 | sha384($pass.$salt) | 3.00 GH/s | 3.00 GH/s | -0.0% |
| 10820 | sha384($salt.$pass) | 2.87 GH/s | 2.87 GH/s | -0.1% |

#### Raw Cipher, Known-plaintext attack

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 14000 | DES (PT = $salt, key = $pass) | 62.71 GH/s | 62.68 GH/s | -0.1% |
| 14100 | 3DES (PT = $salt, key = $pass) | 8.90 GH/s | 8.85 GH/s | -0.6% |
| 26401 | AES-128-ECB NOKDF (PT = $salt, key = $pass) | 8.40 GH/s | 8.34 GH/s | -0.7% |
| 26403 | AES-256-ECB NOKDF (PT = $salt, key = $pass) | 5.96 GH/s | 5.98 GH/s | +0.3% |

#### Raw Checksum

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 11500 | CRC32 | 18.26 GH/s | 18.31 GH/s | +0.3% |
| 18700 | Java Object hashCode() | 625.27 GH/s | 623.47 GH/s | -0.3% |

#### Generic KDF

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 400 | phpass | 20.80 MH/s | 20.73 MH/s | -0.3% |
| 8900 | scrypt | 3.79 kH/s | 3.80 kH/s | +0.4% |
| 34000 | Argon2 | 1.41 kH/s | 1.41 kH/s | -0.1% |

#### Network Protocol

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 5500 | NetNTLMv1 / NetNTLMv1+ESS | 65.85 GH/s | 66.20 GH/s | +0.5% |
| 5600 | NetNTLMv2 | 4.64 GH/s | 4.61 GH/s | -0.6% |
| 13100 | Kerberos 5, etype 23, TGS-REP | 1.46 GH/s | 1.47 GH/s | +0.4% |
| 22000 | WPA-PBKDF2-PMKID+EAPOL | 1.12 MH/s | 1.11 MH/s | -0.5% |

#### Operating System

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 500 | md5crypt, MD5 (Unix), Cisco-IOS $1$ (MD5) | 29.69 MH/s | 29.91 MH/s | +0.7% |
| 1000 | NTLM | 119.31 GH/s | 122.64 GH/s | **+2.8%** |
| 1100 | Domain Cached Credentials (DCC), MS Cache | 33.01 GH/s | 33.04 GH/s | +0.1% |
| 1500 | descrypt, DES (Unix), Traditional DES | 2.53 GH/s | 2.58 GH/s | **+1.9%** |
| 1800 | sha512crypt $6$, SHA512 (Unix) | 475.77 kH/s | 473.90 kH/s | -0.4% |
| 2100 | Domain Cached Credentials 2 (DCC2), MS Cache 2 | 898.31 kH/s | 902.85 kH/s | +0.5% |
| 3000 | LM | 63.97 GH/s | 63.79 GH/s | -0.3% |
| 3200 | bcrypt $2*$, Blowfish (Unix) | 104.59 kH/s | 105.75 kH/s | **+1.1%** |
| 5700 | Cisco-IOS type 4 (SHA256) | 8.78 GH/s | 8.76 GH/s | -0.3% |
| 7100 | macOS v10.8+ (PBKDF2-SHA512) | 1.34 MH/s | 1.34 MH/s | -0.0% |
| 7400 | sha256crypt $5$, SHA256 (Unix) | 881.90 kH/s | 869.25 kH/s | -1.4% |
| 9200 | Cisco-IOS $8$ (PBKDF2-SHA256) | 187.63 kH/s | 161.86 kH/s | -13.7% |
| 9300 | Cisco-IOS $9$ (scrypt) | 137.27 kH/s | 136.97 kH/s | -0.2% |
| 15300 | DPAPI masterkey file v1 (context 1 and 2) | 191.57 kH/s | 191.68 kH/s | +0.1% |
| 15900 | DPAPI masterkey file v2 (context 1 and 2) | 108.38 kH/s | 108.49 kH/s | +0.1% |
| 28100 | Windows Hello PIN/Password | 369.17 kH/s | 371.52 kH/s | +0.6% |
| 33700 | Microsoft Online Account (PBKDF2-HMAC-SHA256 + AES | 320.89 kH/s | 372.68 kH/s | **+16.1%** |
| 35100 | sm3crypt $sm3$, SM3 (Unix) | 836.83 kH/s | 839.15 kH/s | +0.3% |

#### FTP, HTTP, SMTP, LDAP Server

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 1600 | Apache $apr1$ MD5, md5apr1, MD5 (APR) | 29.66 MH/s | 30.05 MH/s | **+1.3%** |
| 8300 | DNSSEC (NSEC3) | 8.21 GH/s | 8.25 GH/s | +0.5% |

#### Database Server

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 300 | MySQL4.1/MySQL5 | 9.94 GH/s | 10.04 GH/s | **+1.1%** |
| 12300 | Oracle T: Type (Oracle 12+) | 337.44 kH/s | 338.23 kH/s | +0.2% |

#### Forums, CMS, E-Commerce

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 2611 | vBulletin < v3.8.5 | 20.27 GH/s | 20.25 GH/s | -0.1% |
| 2711 | vBulletin >= v3.8.5 | 14.14 GH/s | 13.99 GH/s | -1.1% |

#### Document

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 9400 | MS Office 2007 | 367.17 kH/s | 367.55 kH/s | +0.1% |
| 9500 | MS Office 2010 | 184.10 kH/s | 183.33 kH/s | -0.4% |
| 9600 | MS Office 2013 | 28.02 kH/s | 27.98 kH/s | -0.2% |
| 9700 | MS Office <= 2003 $0/$1, MD5 + RC4 | 1.14 GH/s | 1.10 GH/s | -3.8% |
| 9800 | MS Office <= 2003 $3/$4, SHA1 + RC4 | 1.22 GH/s | 1.22 GH/s | -0.4% |
| 10400 | PDF 1.1 - 1.3 (Acrobat 2 - 4) | 1.73 GH/s | 1.73 GH/s | +0.4% |
| 10500 | PDF 1.4 - 1.6 (Acrobat 5 - 8) | 77.17 MH/s | 78.01 MH/s | **+1.1%** |
| 10510 | PDF 1.3 - 1.6 (Acrobat 4 - 8) w/ RC4-40 | 76.39 MH/s | 77.59 MH/s | **+1.6%** |
| 10600 | PDF 1.7 Level 3 (Acrobat 9) | 8.78 GH/s | 8.77 GH/s | -0.1% |
| 10700 | PDF 1.7 Level 8 (Acrobat 10 - 11) | 209.70 kH/s | 209.86 kH/s | +0.1% |

#### Password Manager

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 6800 | LastPass + LastPass sniffed | 37.73 kH/s | 37.74 kH/s | +0.0% |
| 13400 | KeePass (KDBX v2/v3) | 136.33 kH/s | 136.89 kH/s | +0.4% |
| 23100 | Apple Keychain | 4.55 MH/s | 4.51 MH/s | -0.8% |
| 23400 | Bitwarden | 37.78 kH/s | 37.78 kH/s | +0.0% |
| 26100 | Mozilla key4.db | 375.79 kH/s | 376.52 kH/s | +0.2% |

#### Cryptocurrency Wallet

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 11300 | Bitcoin/Litecoin wallet.dat | 14.04 kH/s | 14.02 kH/s | -0.1% |
| 15600 | Ethereum Wallet, PBKDF2-HMAC-SHA256 | 3.64 MH/s | 3.62 MH/s | -0.6% |
| 15700 | Ethereum Wallet, SCRYPT | 16 H/s | 17 H/s | **+6.2%** |
| 16300 | Ethereum Pre-Sale Wallet, PBKDF2-HMAC-SHA256 | 1.85 MH/s | 1.85 MH/s | -0.2% |
| 16600 | Electrum Wallet (Salt-Type 1-3) | 2.04 GH/s | 2.03 GH/s | -0.1% |
| 21700 | Electrum Wallet (Salt-Type 4) | 1.35 MH/s | 1.34 MH/s | -0.7% |
| 21800 | Electrum Wallet (Salt-Type 5) | 1.34 MH/s | 1.34 MH/s | +0.2% |
| 22500 | MultiBit Classic .key (MD5) | 2.20 GH/s | 2.22 GH/s | +0.9% |
| 22700 | MultiBit HD (scrypt) | 3.80 kH/s | 3.80 kH/s | +0.2% |
| 25500 | Stargazer Stellar Wallet XLM | 912.65 kH/s | 904.16 kH/s | -0.9% |
| 26610 | MetaMask Wallet (short hash, plaintext check) | 371.89 kH/s | 371.68 kH/s | -0.1% |
| 27700 | MultiBit Classic .wallet (scrypt) | 3.74 kH/s | 3.77 kH/s | +0.8% |
| 31900 | MetaMask Mobile Wallet | 276.63 kH/s | 275.91 kH/s | -0.3% |

#### Full-Disk Encryption (FDE)

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 12200 | eCryptfs | 42.97 kH/s | 42.96 kH/s | -0.0% |
| 16700 | FileVault 2 | 188.92 kH/s | 188.33 kH/s | -0.3% |
| 18300 | Apple File System (APFS) | 186.58 kH/s | 186.52 kH/s | -0.0% |
| 22100 | BitLocker | 4.11 kH/s | 4.10 kH/s | -0.0% |
| 29341 | TrueCrypt RIPEMD160 + XTS 512 bit + boot-mode | 1.46 MH/s | 1.47 MH/s | +0.5% |
| 29421 | VeraCrypt SHA512 + XTS 512 bit | 2.66 kH/s | 2.71 kH/s | **+1.7%** |
| 29511 | LUKS v1 SHA-1 + AES | 60.47 kH/s | 60.50 kH/s | +0.0% |
| 34100 | LUKS v2 argon2 + SHA-256 + AES | 22 H/s | 22 H/s | +0.0% |

#### Archive

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 11600 | 7-Zip | 1.14 MH/s | 1.15 MH/s | +0.1% |
| 12500 | RAR3-hp | 146.72 kH/s | 146.40 kH/s | -0.2% |
| 13000 | RAR5 | 113.53 kH/s | 114.03 kH/s | +0.4% |
| 13600 | WinZip | 8.83 MH/s | 8.90 MH/s | +0.8% |
| 17200 | PKZIP (Compressed) | 578.50 MH/s | 595.75 MH/s | **+3.0%** |
| 17220 | PKZIP (Compressed Multi-File) | 16.73 GH/s | 16.18 GH/s | -3.3% |
| 20500 | PKZIP Master Key | 231.09 GH/s | 232.62 GH/s | +0.7% |
| 23800 | RAR3-p (Compressed) | 143.99 kH/s | 143.75 kH/s | -0.2% |

#### Private Key

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 17010 | GPG (AES-128/AES-256 (SHA-1($pass))) | 13.22 MH/s | 13.29 MH/s | +0.5% |
| 17030 | GPG (AES-128/AES-256 (SHA-256($pass))) | 5.96 MH/s | 5.96 MH/s | -0.1% |
| 22921 | RSA/DSA/EC/OpenSSH Private Keys ($6$) | 6.23 GH/s | 6.40 GH/s | **+2.8%** |

#### One-Time Password

| Mode | Algorithm | hashcat | hashdog | Δ |
|-----:|-----------|--------:|--------:|---:|
| 18100 | TOTP (HMAC-SHA1) | 4.13 GH/s | 4.04 GH/s | -2.1% |
