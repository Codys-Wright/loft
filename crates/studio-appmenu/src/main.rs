//! `studio-appmenu`: run by the shell (src/services/AppMenu.qml); see
//! `studio_appmenu::protocol` for the stdin/stdout protocol.

#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    if std::env::args()
        .nth(1)
        .is_some_and(|a| a == "--help" || a == "-h")
    {
        println!(
            "studio-appmenu — global menu daemon for studio-linux\n\n\
             Owns com.canonical.AppMenu.Registrar (unless another registrar does;\n\
             STUDIO_APPMENU_REGISTRAR=0 never takes it) and serves the focused\n\
             app's menu as line-JSON. stdin: {{\"cmd\":\"focus\",\"pid\":N}}, activate, open,\n\
             close, refresh, list, dump, quit. stdout: {{\"status\"}}, {{\"menu\"}}, {{\"error\"}}."
        );
        return Ok(());
    }
    studio_appmenu::daemon::run().await
}
