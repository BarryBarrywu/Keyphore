use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const PLUGIN_NAME: &str = "nuphy-codex";
const LAUNCH_LABEL: &str = "com.barrybarrywu.nuphy-codex";
const HOOK_EVENTS: [&str; 8] = [
    "PermissionRequest",
    "PostToolUse",
    "SessionEnd",
    "SessionStart",
    "Stop",
    "SubagentStart",
    "SubagentStop",
    "UserPromptSubmit",
];
const HOOK_COMMAND: &str = "\"${CLAUDE_PLUGIN_ROOT}/bin/nuphy-codex\" hook";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct LifecycleState {
    plugin_id: String,
    plugin_root: PathBuf,
}

pub struct PluginLifecycle {
    data_dir: PathBuf,
    launch_agents_dir: PathBuf,
    launchctl: PathBuf,
    codex: PathBuf,
    launch_domain: String,
}

impl PluginLifecycle {
    pub fn from_environment() -> Result<Self> {
        let home = env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        Ok(Self {
            data_dir: env::var_os("NUPHY_CODEX_DATA_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("Library/Application Support/NuPhy Codex")),
            launch_agents_dir: env::var_os("NUPHY_CODEX_LAUNCH_AGENTS_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("Library/LaunchAgents")),
            launchctl: env::var_os("NUPHY_CODEX_LAUNCHCTL_BIN")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/bin/launchctl")),
            codex: env::var_os("NUPHY_CODEX_CODEX_BIN")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("codex")),
            launch_domain: env::var("NUPHY_CODEX_LAUNCH_DOMAIN")
                .unwrap_or_else(|_| format!("gui/{}", unsafe { libc::geteuid() })),
        })
    }

    pub fn install(&self, plugin_root: &Path, plugin_id: &str) -> Result<()> {
        validate_plugin_id(plugin_id)?;
        validate_plugin_bundle(plugin_root)?;
        if let Some(existing) = self.read_state()? {
            ensure!(
                existing.plugin_id == plugin_id,
                "another NuPhy plugin installation is already managed"
            );
        }
        self.activate(plugin_root, plugin_id)
    }

    pub fn update(&self, plugin_root: &Path, plugin_id: &str) -> Result<()> {
        validate_plugin_id(plugin_id)?;
        validate_plugin_bundle(plugin_root)?;
        let existing = self
            .read_state()?
            .context("NuPhy plugin is not installed")?;
        ensure!(
            existing.plugin_id == plugin_id,
            "update cannot change plugin ownership"
        );
        run_checked_command(
            Command::new(&self.codex)
                .args(["plugin", "add"])
                .arg(plugin_id),
            "failed to update the NuPhy plugin",
        )?;
        self.activate(plugin_root, plugin_id)
    }

    pub fn uninstall(&self) -> Result<()> {
        let state = self
            .read_state()?
            .context("NuPhy plugin is not installed")?;
        validate_plugin_id(&state.plugin_id)?;
        self.stop_companion()?;
        run_checked_command(
            Command::new(&self.codex)
                .args(["plugin", "remove"])
                .arg(&state.plugin_id),
            "failed to remove the NuPhy plugin",
        )?;
        remove_file_if_present(&self.plist_path())?;
        for name in [
            "status.json",
            "status.lock",
            "companion.stdout.log",
            "companion.stderr.log",
        ] {
            remove_file_if_present(&self.data_dir.join(name))?;
        }
        remove_file_if_present(&self.state_path())?;
        match fs::remove_dir(&self.data_dir) {
            Ok(()) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::NotFound | ErrorKind::DirectoryNotEmpty
                ) => {}
            Err(error) => {
                return Err(error).context("failed to remove empty managed data directory");
            }
        }
        Ok(())
    }

    pub fn active_plugin(&self) -> Result<Option<(String, PathBuf)>> {
        Ok(self
            .read_state()?
            .map(|state| (state.plugin_id, state.plugin_root)))
    }

    pub fn companion_status(&self) -> Result<&'static str> {
        let output = Command::new(&self.launchctl)
            .args(["print", &self.launch_target()])
            .output()
            .context("failed to inspect NuPhy companion")?;
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            return Ok(if stdout.contains("state = running") {
                "running"
            } else {
                "loaded-not-running"
            });
        }
        let error = String::from_utf8_lossy(&output.stderr).to_ascii_lowercase();
        if error.contains("could not find service")
            || error.contains("service not found")
            || error.contains("not found")
        {
            return Ok("stopped");
        }
        bail!("failed to determine NuPhy companion state")
    }

    pub fn plugin_is_enabled(&self, plugin_id: &str) -> Result<bool> {
        let output = run_checked_command(
            Command::new(&self.codex).args(["plugin", "list", "--json"]),
            "failed to inspect installed Codex plugins",
        )?;
        let listing: Value =
            serde_json::from_slice(&output.stdout).context("Codex plugin listing is invalid")?;
        Ok(listing["installed"].as_array().is_some_and(|installed| {
            installed.iter().any(|plugin| {
                plugin["pluginId"] == plugin_id && plugin["enabled"].as_bool() == Some(true)
            })
        }))
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    fn start_companion(&self, plugin_root: &Path) -> Result<()> {
        fs::create_dir_all(&self.data_dir).context("failed to create managed data directory")?;
        fs::create_dir_all(&self.launch_agents_dir)
            .context("failed to create LaunchAgents directory")?;
        let plist = launch_agent_plist(
            &plugin_root.join("bin/nuphy-codex"),
            &self.data_dir.join("status.json"),
            &self.data_dir.join("companion.stdout.log"),
            &self.data_dir.join("companion.stderr.log"),
        );
        fs::write(self.plist_path(), plist).context("failed to write NuPhy LaunchAgent")?;
        self.stop_companion()?;
        run_checked_command(
            Command::new(&self.launchctl)
                .arg("bootstrap")
                .arg(&self.launch_domain)
                .arg(self.plist_path()),
            "failed to load NuPhy companion",
        )?;
        run_checked_command(
            Command::new(&self.launchctl).args(["kickstart", "-k", &self.launch_target()]),
            "failed to start NuPhy companion",
        )?;
        Ok(())
    }

    fn stop_companion(&self) -> Result<()> {
        let output = Command::new(&self.launchctl)
            .args(["bootout", &self.launch_target()])
            .output()
            .context("failed to stop NuPhy companion")?;
        if output.status.success() || self.companion_status()? == "stopped" {
            return Ok(());
        }
        bail!("NuPhy companion is still loaded")
    }

    fn activate(&self, plugin_root: &Path, plugin_id: &str) -> Result<()> {
        self.start_companion(plugin_root)?;
        self.write_state(&LifecycleState {
            plugin_id: plugin_id.into(),
            plugin_root: plugin_root.to_owned(),
        })
    }

    fn state_path(&self) -> PathBuf {
        self.data_dir.join("lifecycle.json")
    }

    fn plist_path(&self) -> PathBuf {
        self.launch_agents_dir.join(format!("{LAUNCH_LABEL}.plist"))
    }

    fn launch_target(&self) -> String {
        format!("{}/{LAUNCH_LABEL}", self.launch_domain)
    }

    fn read_state(&self) -> Result<Option<LifecycleState>> {
        match fs::read(self.state_path()) {
            Ok(bytes) => Ok(Some(
                serde_json::from_slice(&bytes).context("managed lifecycle state is invalid")?,
            )),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).context("failed to read managed lifecycle state"),
        }
    }

    fn write_state(&self, state: &LifecycleState) -> Result<()> {
        fs::create_dir_all(&self.data_dir).context("failed to create managed data directory")?;
        let replacement = self
            .data_dir
            .join(format!(".lifecycle.{}.tmp", std::process::id()));
        let mut bytes = serde_json::to_vec(state)?;
        bytes.push(b'\n');
        fs::write(&replacement, bytes).context("failed to write lifecycle replacement")?;
        fs::rename(replacement, self.state_path()).context("failed to replace lifecycle state")
    }
}

pub fn validate_plugin_bundle(plugin_root: &Path) -> Result<()> {
    let manifest: Value = serde_json::from_slice(
        &fs::read(plugin_root.join(".codex-plugin/plugin.json"))
            .context("plugin manifest is missing")?,
    )
    .context("plugin manifest is invalid")?;
    ensure!(
        manifest["name"] == PLUGIN_NAME,
        "plugin manifest has the wrong owner"
    );

    let hooks: Value = serde_json::from_slice(
        &fs::read(plugin_root.join("hooks/hooks.json")).context("plugin Hooks are missing")?,
    )
    .context("plugin Hooks are invalid")?;
    let hooks = hooks["hooks"]
        .as_object()
        .context("plugin Hooks are invalid")?;
    ensure!(
        hooks.len() == HOOK_EVENTS.len(),
        "plugin Hook set is not approved"
    );
    for event in HOOK_EVENTS {
        let definitions = hooks
            .get(event)
            .with_context(|| format!("plugin Hook {event} is missing"))?;
        let handlers = definitions
            .as_array()
            .context("plugin Hook definition is invalid")?;
        ensure!(
            handlers.len() == 1,
            "plugin Hook definition is not singular"
        );
        let hook = &handlers[0]["hooks"];
        let hook = hook.as_array().context("plugin Hook handler is invalid")?;
        ensure!(hook.len() == 1, "plugin Hook handler is not singular");
        ensure!(
            hook[0]["type"] == "command",
            "plugin Hook handler type is not approved"
        );
        ensure!(
            hook[0]["command"] == HOOK_COMMAND,
            "plugin Hook command is not owned by this plugin"
        );
    }

    let binary = plugin_root.join("bin/nuphy-codex");
    let metadata = fs::metadata(&binary).context("bundled companion is missing")?;
    ensure!(metadata.is_file(), "bundled companion is not a file");
    ensure!(
        metadata.permissions().mode() & 0o111 != 0,
        "bundled companion is not executable"
    );
    Ok(())
}

fn validate_plugin_id(plugin_id: &str) -> Result<()> {
    let Some((name, marketplace)) = plugin_id.split_once('@') else {
        bail!("plugin id must include its marketplace")
    };
    ensure!(
        name == PLUGIN_NAME,
        "plugin id is not owned by this project"
    );
    ensure!(
        !marketplace.is_empty()
            && marketplace
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
        "plugin marketplace is invalid"
    );
    Ok(())
}

fn run_checked_command(command: &mut Command, context: &str) -> Result<Output> {
    let output = command.output().with_context(|| context.to_owned())?;
    if !output.status.success() {
        bail!("{context}")
    }
    Ok(output)
}

fn remove_file_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
}

fn launch_agent_plist(binary: &Path, status: &Path, stdout: &Path, stderr: &Path) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key><string>{LAUNCH_LABEL}</string>\n  <key>ProgramArguments</key>\n  <array>\n    <string>{}</string>\n    <string>companion</string>\n    <string>--status</string>\n    <string>{}</string>\n  </array>\n  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n  <key>StandardOutPath</key><string>{}</string>\n  <key>StandardErrorPath</key><string>{}</string>\n</dict>\n</plist>\n",
        xml(binary.as_os_str()),
        xml(status.as_os_str()),
        xml(stdout.as_os_str()),
        xml(stderr.as_os_str()),
    )
}

fn xml(value: &OsStr) -> String {
    value
        .to_string_lossy()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
