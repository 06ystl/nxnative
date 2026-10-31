// Mac motion source selection, calibration menu and optional phone connection.
#pragma once
void dm_motion_mac_start(void);
void dm_motion_mac_set_active(int active);

typedef struct { int phone,can_calibrate; char message[192]; } dm_motion_mac_status;
void dm_motion_mac_select_phone(int phone);
void dm_motion_mac_set_response(double horizontal, double vertical);
void dm_motion_mac_calibrate_now(void);
void dm_motion_mac_connect_phone(void);
dm_motion_mac_status dm_motion_mac_get_status(void);
