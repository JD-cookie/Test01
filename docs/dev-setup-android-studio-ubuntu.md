# Use the Android emulator on Ubuntu

Run Test01 in an Android emulator on your Ubuntu desktop while the code and dev servers stay on the remote dev server. You only need Android Studio for its emulator; the app is not built locally.

## One-time setup

1. **Check that hardware virtualization works.** The emulator is unusably slow without it.
   ```bash
   sudo apt install cpu-checker qemu-kvm
   kvm-ok                                 # should say "KVM acceleration can be used"
   sudo usermod -aG kvm $USER             # then log out and back in
   ```
   If `kvm-ok` fails, turn on VT-x or AMD-V in your BIOS/UEFI settings.

2. **Install Android Studio.**
   ```bash
   sudo snap install android-studio --classic
   ```
   Launch it and go through the setup wizard with the **Standard** options. The wizard installs the SDK, the emulator, and platform tools into `~/Android/Sdk`.

3. **Put the command-line tools on your PATH.** Add these lines to `~/.bashrc`, then open a new terminal:
   ```bash
   export ANDROID_HOME=$HOME/Android/Sdk
   export PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator
   ```

4. **Create a virtual device.** In Android Studio, open **Device Manager** and click **+ Create Virtual Device**. Pick a phone such as a Pixel, and choose a system image that has the **Google Play** icon, so you can install Expo Go. Choose a recent API level and the **x86_64** architecture.

5. **Start the device and install Expo Go.** Start the virtual device and sign in to the Play Store in it. Then install **Expo Go**.

You can also start the emulator without opening Android Studio:
```bash
emulator -list-avds
emulator -avd <name> &
```

## Daily use: connect to the remote dev server

1. **Open the tunnel.** In terminal 1 on your desktop, forward Metro and the API from the dev server:
   ```bash
   ssh -L 8081:localhost:8081 -L 3000:localhost:3000 you@dev-server
   ```

2. **Start the dev servers.** In that SSH session, start the API in one shell and Metro in another, for example using `tmux`:
   ```bash
   cd server && npm run dev
   cd app && REACT_NATIVE_PACKAGER_HOSTNAME=127.0.0.1 npx expo start
   ```

3. **Forward the emulator's ports.** In terminal 2 on your desktop, with the emulator running:
   ```bash
   adb reverse tcp:8081 tcp:8081
   adb reverse tcp:3000 tcp:3000
   ```
   Run these again each time the emulator restarts.

4. **Open the app.** In Expo Go in the emulator, choose **Enter URL manually** and enter `exp://127.0.0.1:8081`. The screen footer should show `development · v… · http://127.0.0.1:3000`.

**If your desktop can reach the dev server directly** (for example, at `10.0.0.78`), skip the tunnel and `adb reverse` steps. Just open `exp://10.0.0.78:8081` in Expo Go.

## While developing

- **Saving a file** on the server updates the emulator straight away.
- **Reload:** press `r` in the Metro terminal, or press `R` twice in the emulator.
- **Dev menu:** press `Ctrl+M` in the emulator, or press `m` in the Metro terminal.
- **Logs:** `console.log` output appears in the Metro terminal. For native logs, run `adb logcat`.
- **Typing:** your desktop keyboard types into the emulator.
- **Rotating and other device controls:** use the emulator's side toolbar.

## Troubleshooting

| Symptom | Fix |
|---|---|
| The emulator is very slow or won't start | Run `kvm-ok`, make sure your user is in the `kvm` group (log out and back in after adding it), and close other virtual machines. |
| `adb: command not found` | The PATH lines from step 3 haven't been loaded. Open a new terminal. |
| No Play Store in the emulator | Create a new virtual device using a system image with the Google Play icon. |
| Expo Go can't connect | Check that the SSH tunnel is still open, then run the `adb reverse` commands again. |
| "Can't reach the server" in the app | Check that the API is running on the server and that port 3000 is in both the `ssh -L` and the `adb reverse` commands. |
