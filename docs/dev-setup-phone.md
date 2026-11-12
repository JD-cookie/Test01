# Set up an Android phone for development

Use your phone to run the development build of Test01. Code changes show up on the phone within seconds.

## One-time setup

1. On the phone, install **Expo Go** from the Play Store.
2. On the dev server, open the firewall if needed: `sudo ufw allow 8081,3000/tcp`.

## Daily use (phone on the same network as the dev server)

```bash
cd server && npm run dev      # terminal 1: API on port 3000
cd app && npx expo start      # terminal 2: Metro on port 8081, prints a QR code
```

Open Expo Go and scan the QR code. If scanning doesn't work, choose **Enter URL manually** and type `exp://<server-ip>:8081`, for example `exp://10.0.0.78:8081`.

The app finds the API on its own at port 3000 of the same host. The footer on each screen shows which server it's using.

## Phone not on the server's network: connect over USB through your computer

This sends the phone's traffic through your computer to the server, using an SSH tunnel.

1. **On the phone, turn on USB debugging.** Go to Settings → About phone and tap **Build number** 7 times. Then go to Settings → System → Developer options and turn on **USB debugging**.
2. **On your computer, install adb:** `sudo apt install android-tools-adb`. Android Studio includes it too.
3. **Connect the phone by USB**, then accept the "Allow USB debugging?" prompt on the phone. Check that the connection works with `adb devices`, which should list the phone as `device`.
4. **Open the tunnel and start Metro.** On your computer, run:
   ```bash
   ssh -L 8081:localhost:8081 -L 3000:localhost:3000 you@dev-server
   ```
   Then, in that SSH session, start the dev servers. Start Metro with this command:
   ```bash
   cd app && REACT_NATIVE_PACKAGER_HOSTNAME=127.0.0.1 npx expo start
   ```
5. **Forward the phone's ports.** In a second terminal on your computer, run:
   ```bash
   adb reverse tcp:8081 tcp:8081
   adb reverse tcp:3000 tcp:3000
   ```
   Run these again whenever you reconnect the phone.
6. **Open the app.** In Expo Go, enter the URL `exp://127.0.0.1:8081`.

## While developing

- **Saving a file** updates the app straight away.
- **Reload:** press `r` in the Metro terminal.
- **Dev menu:** shake the phone, or press `m` in the Metro terminal.
- **Logs:** `console.log` output appears in the Metro terminal.
- **Mirror the phone onto your computer:** install `scrcpy` with `sudo apt install scrcpy`, then run `scrcpy` with the phone connected by USB. This shows the phone's screen in a window that you can control with your mouse and keyboard.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Expo Go can't connect | Check that the phone is on the same network, that the firewall allows port 8081, or use the USB method above. |
| App loads but says "Can't reach the server" | Check that the API is running on port 3000, that port 3000 is open or forwarded, and what the footer URL shows. |
| `adb devices` shows `unauthorized` | Unlock the phone and accept the USB debugging prompt. |
| Expo Go says the project needs a newer SDK | Update Expo Go from the Play Store. |
