const { spawn } = require("node:child_process");
const fs = require("fs");
const path = require("path");
const { dialog } = require("electron");

let recordingProcess = null;

const initRecording = (filepath, filename) => {
  return new Promise((resolve) => {
    // Fallback to a default filename if not provided
    let safeFilename = filename;
    if (
      !safeFilename ||
      typeof safeFilename !== "string" ||
      !safeFilename.trim()
    ) {
      safeFilename = `output_${Date.now()}`;
    }
    const outputPath = path.join(filepath, safeFilename + ".mov");
    recordingProcess = spawn("./src/swift/Recorder", [outputPath]);

    global.mainWindow.webContents.send(
      "recording-status",
      "START_RECORDING",
      Date.now(),
      outputPath
    );
    resolve(true);
  });
};

module.exports.startRecording = async ({ filepath, filename }) => {
  const fullPath = path.join(filepath, filename + ".mov");
  if (fs.existsSync(fullPath)) {
    dialog.showMessageBox({
      type: "error",
      title: "Recording Error",
      message:
        "File already exists. Please choose a different filename or delete the existing file.",
      buttons: ["OK"],
    });
    global.mainWindow.loadFile("./src/electron/screens/recording/screen.html");
    return;
  }

  while (true) {
    const recordingStarted = await initRecording(filepath, filename);
    if (recordingStarted) {
      break;
    }
  }
};

module.exports.stopRecording = () => {
  if (recordingProcess !== null) {
    // Send 'stop' to stdin to stop the Swift CLI
    recordingProcess.stdin.write("stop\n");
    recordingProcess = null;
    global.mainWindow.webContents.send(
      "recording-status",
      "STOP_RECORDING",
      Date.now(),
      null
    );
  }
};
