use std::{thread, time::Duration};

use anyhow::Result;
use clap::{Parser, Subcommand};
use nuphy_codex::diagnostic::{exercise_main_backlight, generate_session_challenge};
use nuphy_codex::hid::discover_air65_v3;

#[derive(Parser)]
#[command(name = "nuphy-codex", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Discover the verified Air65 V3 over wired USB.
    ///
    /// No lighting report is sent unless --exercise is provided.
    Diagnose {
        /// Apply a blue execution effect for three seconds, then turn the main backlight off.
        #[arg(long)]
        exercise: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Diagnose { exercise } => diagnose(exercise),
    }
}

fn diagnose(exercise: bool) -> Result<()> {
    let mut keyboard = discover_air65_v3()?;
    println!(
        "supported device: NuPhy {} (USB {:04x}:{:04x}, interface {}, usage {:04x}:{:04x})",
        keyboard.descriptor.product,
        keyboard.descriptor.vendor_id,
        keyboard.descriptor.product_id,
        keyboard.descriptor.interface_number,
        keyboard.descriptor.usage_page,
        keyboard.descriptor.usage,
    );

    if !exercise {
        println!("discovery only: no lighting report was sent");
        return Ok(());
    }

    let evidence = exercise_main_backlight(
        &mut keyboard.transport,
        generate_session_challenge(),
        || {
            println!("blue execution effect verified by readback; observing for 3 seconds");
            thread::sleep(Duration::from_secs(3));
        },
    )?;
    println!(
        "signal-off verified; rhythm light bar unchanged ({:02x?})",
        evidence.rhythm_after_off
    );
    Ok(())
}
