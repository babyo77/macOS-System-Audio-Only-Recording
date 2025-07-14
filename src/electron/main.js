const { app, BrowserWindow, ipcMain, dialog, shell } = require("electron");
const os = require("os");
const path = require("path");

const { startRecording, stopRecording } = require("./utils/recording");

const createWindow = async () => {
  global.mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      enableRemoteModule: true,
      devTools: false,
    },
  });

  global.mainWindow.loadFile("./src/electron/screens/recording/screen.html");
};

ipcMain.on("open-folder-dialog", async (event) => {
  const desktopPath = path.join(os.homedir(), "Desktop");

  const { filePaths, canceled } = await dialog.showOpenDialog(
    global.mainWindow,
    {
      properties: ["openDirectory"],
      buttonLabel: "Select Folder",
      title: "Select a folder",
      message: "Please select a folder for saving the recording",
      defaultPath: desktopPath,
    }
  );

  if (!canceled) {
    event.sender.send("selected-folder", filePaths[0]);
  }
});

ipcMain.on("start-recording", async (_, { filepath, filename }) => {
  await startRecording({
    filepath,
    filename,
  });
});

ipcMain.on("stop-recording", () => {
  stopRecording();
});

app.whenReady().then(createWindow);
