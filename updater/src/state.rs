use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, fs, path::Path, path::PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UpdateStatus {
    Idle,
    CheckingUpstream,
    UpdateDetected,
    DownloadingDmg,
    PreparingWorkspace,
    PatchingApp,
    BuildingDeb,
    ReadyToInstall,
    WaitingForAppExit,
    Installing,
    Installed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct ArtifactPaths {
    pub dmg_path: Option<PathBuf>,
    pub workspace_dir: Option<PathBuf>,
    pub deb_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersistedState {
    pub installed_version: String,
    pub candidate_version: Option<String>,
    pub status: UpdateStatus,
    pub last_check_at: Option<DateTime<Utc>>,
    pub last_successful_check_at: Option<DateTime<Utc>>,
    pub remote_headers_fingerprint: Option<String>,
    pub dmg_sha256: Option<String>,
    pub artifact_paths: ArtifactPaths,
    pub error_message: Option<String>,
    pub notified_events: BTreeSet<String>,
    pub auto_install_on_app_exit: bool,
}

impl PersistedState {
    pub fn new(auto_install_on_app_exit: bool) -> Self {
        Self {
            installed_version: "unknown".to_string(),
            candidate_version: None,
            status: UpdateStatus::Idle,
            last_check_at: None,
            last_successful_check_at: None,
            remote_headers_fingerprint: None,
            dmg_sha256: None,
            artifact_paths: ArtifactPaths::default(),
            error_message: None,
            notified_events: BTreeSet::new(),
            auto_install_on_app_exit,
        }
    }

    pub fn load_or_default(path: &Path, auto_install_on_app_exit: bool) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::new(auto_install_on_app_exit));
        }

        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read {}", path.display()))?;
        let state = serde_json::from_str::<Self>(&content)
            .with_context(|| format!("Failed to parse {}", path.display()))?;
        Ok(state)
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let content = serde_json::to_string_pretty(self)?;
        fs::write(path, content).with_context(|| format!("Failed to write {}", path.display()))?;
        Ok(())
    }

    pub fn mark_failed(&mut self, message: impl Into<String>) {
        self.status = UpdateStatus::Failed;
        self.error_message = Some(message.into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use tempfile::tempdir;

    #[test]
    fn creates_default_state_when_missing() -> Result<()> {
        let temp = tempdir()?;
        let state = PersistedState::load_or_default(&temp.path().join("state.json"), true)?;
        assert_eq!(state.status, UpdateStatus::Idle);
        assert!(state.auto_install_on_app_exit);
        Ok(())
    }

    #[test]
    fn roundtrips_persisted_state() -> Result<()> {
        let temp = tempdir()?;
        let path = temp.path().join("state.json");
        let mut state = PersistedState::new(false);
        state.installed_version = "2026.03.24+deadbeef".to_string();
        state.status = UpdateStatus::WaitingForAppExit;
        state.candidate_version = Some("2026.03.25+feedface".to_string());
        state.notified_events.insert("ready_to_install".to_string());
        state.save(&path)?;

        let loaded = PersistedState::load_or_default(&path, true)?;
        assert_eq!(loaded.installed_version, "2026.03.24+deadbeef");
        assert_eq!(loaded.status, UpdateStatus::WaitingForAppExit);
        assert_eq!(
            loaded.candidate_version.as_deref(),
            Some("2026.03.25+feedface")
        );
        assert!(loaded.notified_events.contains("ready_to_install"));
        assert!(!loaded.auto_install_on_app_exit);
        Ok(())
    }
}
