#pragma once
// Select optional, game-local UI resources once, before the guest mounts RomFS.
// The game's cached UI keeps this choice until restart.
int dm_controller_ui_mac_select(int dualsense);
int dm_controller_ui_mac_available(void);
void dm_controller_ui_mac_set_app_bundle(const char *path);
