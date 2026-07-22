# Office sync — push instructions

Local git is already prepared on this machine:

```
/home/mehran/kernel-s9plus
branch: main
commits:
  7a421a6a Initial sync: S9+ PE HDMI/DP bring-up (#35)
  0df93b9f Remove nested git backup objects from the tree
```

## One-time: create remote + push (run in a terminal)

```bash
# 1) Login (browser)
gh auth login -h github.com -p https -w

# 2) Create private repo and push (~230MB pack; needs good uplink)
cd /home/mehran/kernel-s9plus
gh repo create kernel-s9plus-hdmi --private --source=. --remote=origin --push
```

If the repo already exists empty:

```bash
cd /home/mehran/kernel-s9plus
git remote add origin https://github.com/Skyshadow2022/kernel-s9plus-hdmi.git
git push -u origin main
```

## On the office PC

```bash
gh repo clone Skyshadow2022/kernel-s9plus-hdmi
cd kernel-s9plus-hdmi
# install clang + aarch64 gcc, then:
./build_gkilike.sh
```

Included: `kernel_source/`, `STABLE`/`NEXT` zips, `hdmi-mirror-v1.3`, scripts, `HDMI_READY.md`.
