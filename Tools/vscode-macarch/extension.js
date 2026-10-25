// Connects VS Code's debugger to MacArch, which serves the Debug Adapter
// Protocol on a localhost port (Settings > Debugging). Starts MacArch if
// it isn't running.

const vscode = require("vscode");
const net = require("net");
const { execFile } = require("child_process");

const bundleID = "com.accidentalfish.macarch";
const defaultPort = 3200;

function canConnect(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: "127.0.0.1", port }, () => {
      socket.end();
      resolve(true);
    });
    socket.on("error", () => resolve(false));
  });
}

async function waitForMacArch(port) {
  if (await canConnect(port)) return;
  await new Promise((resolve) => execFile("open", ["-g", "-b", bundleID], () => resolve()));
  for (let i = 0; i < 100; i++) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    if (await canConnect(port)) return;
  }
  throw new Error(`MacArch isn't listening on port ${port}. Is it installed, with a ROM chosen and debugging on in Settings > Debugging?`);
}

function activate(context) {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("macarch", {
      async createDebugAdapterDescriptor(session) {
        const port = session.configuration.port || defaultPort;
        await waitForMacArch(port);
        return new vscode.DebugAdapterServer(port, "127.0.0.1");
      },
    }),
    vscode.debug.registerDebugConfigurationProvider("macarch", {
      resolveDebugConfiguration(folder, config) {
        // F5 with no launch.json: assemble and run the ARM source in the
        // editor, or run the BASIC program.
        if (!config.type && !config.request) {
          const editor = vscode.window.activeTextEditor;
          if (editor && editor.document.languageId === "arm-macarch") {
            config.type = "macarch";
            config.request = "launch";
            config.name = "Assemble and run";
            config.source = editor.document.fileName;
          } else if (editor && editor.document.languageId === "bbcbasic") {
            config.type = "macarch";
            config.request = "launch";
            config.name = "Run BASIC on the Archimedes";
            config.basic = editor.document.fileName;
          }
        }
        // Save before assembling (or loading BASIC).
        if (config.source || config.basic) {
          return vscode.workspace.saveAll(false).then(() => config);
        }
        return config;
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
