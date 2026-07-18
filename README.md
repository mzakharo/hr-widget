# Connect IQ heart rate widget
See https://apps.garmin.com/en-GB/apps/ea97fdfa-0339-464e-a665-d4dfcbc9a4d2 for the app store page.

Feel free to use any of the code here, the chart is intended to be fairly re-usable.
I'd appreciate being credited though :-)

## Building in Visual Studio Code

1. Install the [Connect IQ SDK Manager](https://developer.garmin.com/connect-iq/sdk/) and use it to install a Connect IQ SDK.
2. Open this repository in VS Code and install the recommended **Monkey C** extension from Garmin.
3. In the extension settings, select the installed SDK and generate or select a developer key.
4. Press **Ctrl+Shift+B** and pick a build task:
   - **Connect IQ: Build widget** (default) uses `monkey.jungle` / `manifest-widget.xml`.
   - **Connect IQ: Build watch app** uses `app.jungle` / `manifest-app.xml`.
5. Enter a supported device ID (default: `fenix3`) and the absolute path to the developer key when prompted. Output is written to `bin/`.

The tasks require `monkeyc` to be available on `PATH`. If it is not, add the active SDK's `bin` directory to `PATH` and restart VS Code. The Garmin extension can also build or debug the default `monkey.jungle` project directly via Run and Debug.
