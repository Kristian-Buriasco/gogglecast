# DJI Fly 1.21.12 DUML command table (`libsdk_jni.so`, arm64)

Generated 2026-10-03 from `~/dji-fly-libs/lib/arm64-v8a/libsdk_jni.so` (DJI Fly 1.21.12.1030, build 3131451).

**Method.** The library is packed: no `.dynsym`, no relocations, and section headers that `llvm-objdump` rejects. The dynamic string table is still in plaintext, though, and it keeps every exported template instantiation `uav::core::uav_cmd_base_req<uint8 type, uint8 cmd_set, uint8 cmd_id, Req, Rsp>`. The mangled form looks like `_ZN3uav4core16uav_cmd_base_reqILh1ELh0ELh50E31uav_general_activate_device_req…`. Every `ILh<n>E` argument and every length-prefixed struct name was parsed and de-duplicated. **448 distinct (set, id, req) entries** came out, up from 416 in the older `libdjisdk_jni.so` (`dji::` namespace). Every entry has template `type` = 1, so that argument is the pack/protocol version (V1 = DUML). It is **not** the cmd_type byte on the wire.

**Caveats.**
- Only commands built through the generic template are listed here. Many push packs are separate classes (`uav::core::fc_osd_push`, `radio_signal_push`, `linkquality_push`, `rc_glass_state_to_app_push`, …). Their set/id live in code that the packer keeps us from resolving statically. They are listed in the push section at the end, by name only.
- Several ids appear twice with different struct names (for example 00:28, 03:2A, 03:BC, 0A:9B). In those cases the same id serves different products.
- Tags in the **flag** column: ★ = matches the telemetry, link, registration or push keyword set. ⛔ = name suggests a write, control or side effect (excluded from any probe).

## Highlights (telemetry / registration / subscription relevant)

| set:id | name | req / rsp | notes |
|---|---|---|---|
| 00:01 | `uav_general_get_get_version_req` | `uav_general_get_get_version_rsp` |  |
| 00:0E | `uav_general_heartbeat_req` | `uav_general_heartbeat_rsp` | heartbeat (RC pushes this; `RcConnectionHeartbeatCaptureV1` observes 00:0E) |
| 00:32 | `uav_general_activate_device_req` | `uav_general_activate_device_rsp` |  |
| 00:36 | `uav_general_deactivate_device_req` | `uav_general_deactivate_device_rsp` |  |
| 00:4F | `uav_general_get_get_version_config_req` | `uav_general_get_get_version_config_rsp` |  |
| 00:76 | `uav_general_event_track_push_push` | `uav_general_push_event_track_push_rsp` |  |
| 00:88 | `uav_general_get_query_device_information_req` | `uav_general_get_query_device_information_rsp` | **App registration ("APP", sub-cmd 0x17) + device heartbeat query (sub 0x19 → reply 0x1a).** Byte-exact payload recovered statically and matches a real N3 capture. See telemetry-registration-sequence.md |
| 00:8C | `uav_general_download_status_push` | `uav_general_push_upgrade_file_download_status_push_rsp` |  |
| 00:8D | `uav_general_set_sleep_negotiate_req` | `uav_general_set_sleep_negotiate_rsp` |  |
| 00:97 | `uav_general_link_monitor_request` | `uav_general_link_monitor_response` | link monitor request (0xE0-rejected from 0x2A earlier) |
| 00:99 | `uav_general_united_pub_sub_agent_req` | `uav_general_united_pub_sub_agent_rsp` | XRCE-DDS pub/sub agent. All 51 DDS topics in this build are **camera** topics (camcap_*, cam_*, pano_*) |
| 00:B5 | `uav_general_get_exclusive_set_subscribe_req` | `uav_general_get_exclusive_set_subscribe_rsp` | exclusive_set_subscribe: semantics unknown (may claim exclusivity). Not sent |
| 00:B6 | `uav_general_get_exclusive_set_push_req` | `uav_general_get_exclusive_set_push_rsp` |  |
| 00:B7 | `uav_general_get_static_cap_req` | `uav_general_get_static_cap_rsp` | static capability get (GoggleStaticCapabilityHelper) |
| 00:B8 | `uav_general_get_function_discover_req` | `uav_general_get_function_discover_rsp` | function discover (GogglesFunctionIDCallback) |
| 00:FE | `uav_general_heartbeat_req` | `uav_general_heartbeat_rsp` | second heartbeat id, same struct; candidate for app→device 1 Hz heartbeat |
| 00:FF | `uav_general_get_device_info_req` | `uav_general_get_device_info_rsp` |  |
| 01:01 | `uav_special_special_ctrl_push` | `uav_special_special_ctrl_rsp` |  |
| 01:0A | `uav_special_SPECIAL_TLV_CMD_push` | `uav_special_push_SPECIAL_TLV_CMD_rsp` |  |
| 02:58 | `uav_camera_set_gps_coordinate_req` | `uav_camera_set_gps_coordinate_rsp` |  |
| 02:59 | `uav_camera_get_gps_coordinate_req` | `uav_camera_get_gps_coordinate_rsp` |  |
| 02:60 | `uav_camera_set_histogram_push_enable_req` | `uav_camera_set_histogram_push_enable_rsp` |  |
| 02:61 | `uav_camera_get_histogram_push_enable_req` | `uav_camera_get_histogram_push_enable_rsp` |  |
| 02:8F | `uav_camera_push_settings_update_notify_rsp` | `uav_camera_settings_update_notify_push` |  |
| 02:B3 | `uav_camera_get_app_request_i_frame_req` | `uav_camera_get_app_request_i_frame_rsp` |  |
| 02:EB | `uav_camera_set_camera_status_subscribe_req` | `uav_camera_set_camera_status_subscribe_rsp` | camera status subscribe. Not sent (payload unknown) |
| 03:46 | `uav_fc_switch_gps_snr_push_req` | `uav_fc_switch_gps_snr_push_rsp` | FC GPS SNR push switch. FC, not sent |
| 03:52 | `uav_fc_confirm_electricity_gohome_req` | `uav_fc_confirm_electricity_gohome_rsp` |  |
| 03:5B | `uav_fc_capability_set_subscribe_push` | `uav_fc_push_capability_set_subscribe_rsp` | FC capability subscribe. FC, not sent |
| 03:5C | `uav_fc_capability_set_push_push` | `uav_fc_push_capability_set_push_rsp` |  |
| 03:A0 | `uav_fc_agnss_pos_and_time_data_push` | `uav_fc_push_agnss_pos_and_time_data_rsp` |  |
| 03:A2 | `uav_fc_agps_online_push_push` | `uav_fc_push_agps_online_push_rsp` |  |
| 03:AF | `uav_fc_get_product_config_req` | `uav_fc_get_product_config_rsp` |  |
| 03:DA | `uav_fc_mc_monitor_req` | `uav_fc_mc_monitor_rsp` |  |
| 03:EE | `uav_fc_get_app_count_down_push_req` | `uav_general_set_device_date_rsp` |  |
| 04:12 | `uav_gimbal_get_message_subscription_req` | `uav_gimbal_get_message_subscription_rsp` | gimbal message subscription. Not sent (payload unknown) |
| 05:08 | `uav_centerboard_get_request_battery_history_state_req` | `uav_centerboard_get_request_battery_history_state_rsp` |  |
| 05:09 | `uav_centerboard_battery_self_discharge_req` | `uav_centerboard_battery_self_discharge_rsp` |  |
| 05:21 | `uav_centerboard_get_request_battery_static_info_req` | `uav_centerboard_get_request_battery_static_info_rsp` |  |
| 05:33 | `uav_centerboard_get_get_battery_barcode_req` | `uav_centerboard_get_get_battery_barcode_rsp` |  |
| 06:6B | `uav_rc_UAV_RACING_RC_VIBRATING_MOTOR_CTRL_push` | `uav_rc_push_UAV_RACING_RC_VIBRATING_MOTOR_CTRL_rsp` |  |
| 06:8C | `uav_rc_set_app_work_stage_set_req` | `uav_rc_set_app_work_stage_set_rsp` |  |
| 06:A1 | `uav_rc_push_data_sync_rsp` | `` |  |
| 06:F1 | `uav_rc_set_app_to_pc_control_req` | `uav_rc_set_app_to_pc_control_rsp` |  |
| 07:28 | `uav_wifi_get_sdr_channel_info_req` | `uav_wifi_get_sdr_channel_info_rsp` |  |
| 07:29 | `uav_wifi_request_snr_req` | `uav_wifi_request_snr_rsp` | request SNR (0xE4 from 0x1B earlier: needs payload) |
| 07:45 | `uav_wifi_device_permission_verification_req` | `uav_wifi_device_permission_verification_rsp` |  |
| 07:46 | `uav_wifi_push_device_permission_verification_asyn_result_rsp` | `` |  |
| 07:93 | `uav_wifi_sw_dev_info_1_push` | `uav_wifi_request_snr_rsp` | wifi sw_dev_info push app→wifi gnd 0x1B (37-byte payload: 01, port u16, 04, …, ip/ssid string). WiFi-link only |
| 07:93 | `uav_wifi_sw_dev_info_push` | `uav_wifi_request_snr_rsp` | wifi sw_dev_info push app→wifi gnd 0x1B (37-byte payload: 01, port u16, 04, …, ip/ssid string). WiFi-link only |
| 07:BA | `uav_wifi_device_capability_nego_req` | `uav_wifi_device_capability_nego_rsp` |  |
| 08:32 | `uav_dm368_sdr_data_report_push_push` | `uav_dm368_push_sdr_data_report_push_rsp` |  |
| 09:09 | `uav_ofdm_frequency_power_push_request_req` | `uav_ofdm_frequency_power_push_request_rsp` | ofdm frequency/power push request. Payload unknown |
| 09:0D | `uav_ofdm_set_config_info_req` | `uav_ofdm_set_config_info_rsp` |  |
| 09:21 | `uav_ofdm_get_sdr_conf_req` | `uav_ofdm_get_sdr_conf_rsp` |  |
| 09:26 | `uav_ofdm_read_sdr_param_req` | `uav_ofdm_read_sdr_param_rsp` |  |
| 09:27 | `uav_ofdm_set_sdr_param_req` | `uav_ofdm_set_sdr_param_rsp` |  |
| 09:39 | `uav_ofdm_set_sdr_config_info_req` | `uav_ofdm_set_sdr_config_info_rsp` |  |
| 09:44 | `uav_ofdm_sdr_role_revert_req` | `uav_ofdm_sdr_role_revert_rsp` |  |
| 09:4B | `device_ofdm_sdr_dongle_state_req` | `device_ofdm_sdr_dongle_state_rsp` |  |
| 09:4D | `uav_ofdm_get_hdvt_mode_get_req` | `uav_ofdm_get_hdvt_mode_get_rsp` |  |
| 09:4E | `uav_ofdm_set_hdvt_mode_switch_req` | `uav_ofdm_set_hdvt_mode_switch_rsp` |  |
| 09:A0 | `uav_ofdm_get_sssfn_req` | `uav_ofdm_get_sssfn_rsp` |  |
| 09:B3 | `uav_ofdm_set_selete_fpv_req` | `uav_ofdm_set_selete_fpv_rsp` |  |
| 09:F9 | `uav_ofdm_RELAY_FREQ_PEER_START_req` | `uav_ofdm_RELAY_FREQ_PEER_START_rsp` |  |
| 09:FA | `uav_ofdm_RELAY_FUNC_req` | `uav_ofdm_RELAY_FUNC_rsp` |  |
| 09:FD | `uav_ofdm_gnd_decoder_ability_feedback_push` | `uav_ofdm_push_gnd_decoder_ability_feedback_rsp` |  |
| 0A:1B | `uav_vision_free_pano_cap_area_info_push` | `uav_vision_push_free_pano_cap_area_info_rsp` |  |
| 0A:62 | `uav_vision_set_visual_stablize_app_state_req` | `uav_vision_set_visual_stablize_app_state_rsp` |  |
| 0A:7D | `uav_vision_set_app_camera_calibration_cmd_req` | `uav_vision_set_app_camera_calibration_cmd_rsp` |  |
| 0A:E7 | `uav_vision_tracking_box_to_nav_push` | `uav_vision_push_tracking_box_to_nav_rsp` |  |
| 0A:EC | `uav_vision_get_navi_homing_receive_msg_from_APP_req` | `uav_vision_get_navi_homing_receive_msg_from_APP_rsp` |  |
| 0D:01 | `uav_smart_battery_get_static_info_req` | `uav_smart_battery_get_static_info_rsp` |  |
| 0D:02 | `uav_smart_battery_get_dynamic_info_req` | `uav_smart_battery_get_dynamic_info_rsp` | battery dynamic info (works on 0x59: goggles battery %) |
| 0D:03 | `uav_smart_battery_get_cell_voltage_req` | `uav_smart_battery_get_cell_voltage_rsp` |  |
| 0D:04 | `uav_smart_battery_get_get_barcode_req` | `uav_smart_battery_get_get_barcode_rsp` |  |
| 0D:11 | `uav_smart_battery_set_self_discharge_req` | `uav_smart_battery_set_self_discharge_rsp` |  |
| 0D:24 | `uav_smart_battery_param_collect_req` | `uav_smart_battery_param_collect_rsp` |  |
| 0D:C4 | `uav_smart_battery_get_full_charge_condition_req` | `uav_smart_battery_get_full_charge_condition_rsp` |  |
| 0D:EF | `uav_smart_battery_clear_user_pd_blacklist_req` | `uav_smart_battery_clear_user_pd_blacklist_rsp` |  |
| 11:43 | `uav_adsb_set_app_update_pos_enc_req` | `uav_adsb_set_app_update_pos_enc_rsp` |  |
| 11:D5 | `uav_adsb_china_oid_publish_push` | `uav_adsb_push_china_oid_publish_rsp` |  |
| 12:22 | `uav_bt_get_hw_product_id_req` | `uav_bt_get_hw_product_id_rsp` |  |
| 15:35 | `uav_goggles_app_to_glass_push_data_push` | `uav_goggles_push_app_to_glass_push_data_rsp` | goggles app→glass push data |
| 18:45 | `uav_cellular4g_get_dongle_subscribe_info_req` | `uav_cellular4g_get_dongle_subscribe_info_rsp` |  |
| 21:05 | `uav_heathy_set_set_subscriber_req` | `uav_heathy_set_set_subscriber_rsp` | HMS (health) set_subscriber, `HMSDiagnosticsHandler::SendSubscribeHMSPack`. Payload unknown |
| 22:80 | `uav_fc_fs_cnt_down_to_app_push` | `uav_fc_push_fs_cnt_down_to_app_rsp` |  |
| 22:CB | `uav_fc2_RC_DYN_HOMEPOINT_INFO_push` | `uav_fc2_push_RC_DYN_HOMEPOINT_INFO_rsp` |  |
| 23:04 | `uav_navigation_api_msg_result_ind_t_push` | `uav_navigation_push_api_msg_result_ind_t_rsp` |  |
| 23:A0 | `uav_navigation_set_keep_sticks_switch_req` | `uav_navigation_set_keep_sticks_switch_rsp` |  |
| 23:B6 | `uav_navigation_fancy_mode_intend_from_app_req` | `uav_navigation_push_fancy_mode_intend_from_app_rsp` |  |
| 51:02 | `uav_wlm_get_link_mode_switch_req` | `uav_wlm_get_link_mode_switch_rsp` |  |
| 51:09 | `uav_wlm_wlm_test_info_req` | `uav_wlm_wlm_test_info_rsp` |  |
| 51:0D | `uav_wlm_get_wlm_debug_control_req` | `uav_wlm_get_wlm_debug_control_rsp` |  |
| 51:15 | `uav_wlm_get_dev_select_req` | `uav_wlm_get_dev_select_rsp` |  |
| 51:1A | `uav_wlm_service_mode_switch_req` | `uav_wlm_service_mode_switch_rsp` |  |
| 51:1E | `uav_wlm_DUSS_MB_CMD_WL_MANAGE_RM_CTRL_REPORT_push` | `uav_wlm_push_DUSS_MB_CMD_WL_MANAGE_RM_CTRL_REPORT_rsp` |  |
| 51:2B | `uav_wlm_wlm_app_conn_product_info_push` | `uav_wlm_push_wlm_app_conn_product_info_rsp` | app_conn_product_info **push** app→wlm, cmd_type 0x00, receiver type 0x0E index 7 (addr 0xEE). Payload built by an unresolved function |
| 51:42 | `uav_wlm_wlm_ability_nego_result_req` | `uav_wlm_wlm_ability_nego_result_rsp` |  |
| 59:03 | `uav_diag_get_sys_diag_keep_alive_req` | `uav_diag_get_sys_diag_keep_alive_rsp` |  |
| EE:02 | `uav_app_phone_camera_info_push` | `uav_app_push_phone_camera_info_rsp` |  |
| EE:07 | `uav_app_app_running_state_push` | `uav_app_push_app_running_state_rsp` | app running state push (foreground/background) |
| EE:08 | `uav_app_get_app_running_state_rsp` | `uav_app_get_app_running_state_req` |  |
| EE:12 | `uav_app_push_app_state_sync_req` | `uav_app_push_app_state_sync_rsp` | app state sync (`app_state_sync_pack`) |
| EE:2C | `uav_app_set_language_settings_req` | `uav_app_set_language_settings_rsp` |  |

## Full table


### cmd_set 0x00: general

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 00:00 | 0 | `uav_general_ping_req` | `uav_general_ping_rsp` |  |
| 00:01 | 1 | `uav_general_get_get_version_req` | `uav_general_get_get_version_rsp` | ★ |
| 00:0B | 11 | `uav_general_set_reboot_device_req` | `uav_general_set_reboot_device_rsp` | ⛔ |
| 00:0E | 14 | `uav_general_heartbeat_req` | `uav_general_heartbeat_rsp` | ★ |
| 00:12 | 18 | `uav_general_find_uav_req` | `uav_general_find_uav_rsp` |  |
| 00:1F | 31 | `uav_general_get_get_file_data_req` | `uav_general_get_get_file_data_rsp` | ⛔ |
| 00:20 | 32 | `uav_general_get_get_file_list_req` | `uav_general_get_get_file_list_rsp` | ⛔ |
| 00:26 | 38 | `uav_general_transfer_msg_req` | `uav_general_transfer_msg_rsp` | ⛔ |
| 00:28 | 40 | `uav_general_delete_drive_file_req` | `uav_general_delete_file_rsp` | ⛔ |
| 00:28 | 40 | `uav_general_delete_file_req` | `uav_general_delete_file_rsp` | ⛔ |
| 00:2A | 42 | `uav_general_general_file_transfer_req` | `uav_general_general_file_transfer_rsp` | ⛔ |
| 00:32 | 50 | `uav_general_activate_device_req` | `uav_general_activate_device_rsp` | ★ ⛔ |
| 00:34 | 52 | `uav_general_buried_messages_req` | `uav_general_buried_messages_rsp` |  |
| 00:36 | 54 | `uav_general_deactivate_device_req` | `uav_general_deactivate_device_rsp` | ★ ⛔ |
| 00:44 | 68 | `uav_general_set_temperature_test_set_req` | `uav_general_set_temperature_test_set_rsp` | ⛔ |
| 00:4A | 74 | `uav_general_set_device_date_req` | `uav_general_set_device_date_rsp` | ⛔ |
| 00:4A | 74 | `uav_general_set_device_date_with_utc_req` | `uav_general_set_device_date_rsp` | ⛔ |
| 00:4B | 75 | `uav_general_get_device_date_req` | `uav_general_get_device_date_rsp` |  |
| 00:4F | 79 | `uav_general_get_get_version_config_req` | `uav_general_get_get_version_config_rsp` | ★ |
| 00:51 | 81 | `uav_general_get_fetch_serial_number_req` | `uav_general_get_fetch_serial_number_rsp` |  |
| 00:6A | 106 | `uav_general_time_manage_req` | `uav_general_set_device_date_v2_rsp` |  |
| 00:70 | 112 | `uav_general_debug_cmd_req` | `uav_general_debug_cmd_rsp` | ⛔ |
| 00:72 | 114 | `uav_general_set_upgrade_notification_req` | `uav_general_set_upgrade_notification_rsp` | ⛔ |
| 00:74 | 116 | `uav_general_accesslocker_v1_encryption_result_req` | `uav_general_get_accesslocker_v1_common_rsp` | ⛔ |
| 00:76 | 118 | `uav_general_event_track_push_push` | `uav_general_push_event_track_push_rsp` | ★ |
| 00:88 | 136 | `uav_general_get_query_device_information_req` | `uav_general_get_query_device_information_rsp` | ★ ⛔ |
| 00:8C | 140 | `uav_general_download_status_push` | `uav_general_push_upgrade_file_download_status_push_rsp` | ★ ⛔ |
| 00:8D | 141 | `uav_general_set_sleep_negotiate_req` | `uav_general_set_sleep_negotiate_rsp` | ★ ⛔ |
| 00:91 | 145 | `uav_general_set_rndis_status_req` | `uav_general_set_rndis_status_rsp` | ⛔ |
| 00:96 | 150 | `uav_general_get_enter_force_upgrade_req` | `uav_general_get_enter_force_upgrade_rsp` | ⛔ |
| 00:97 | 151 | `uav_general_link_monitor_request` | `uav_general_link_monitor_response` | ★ |
| 00:99 | 153 | `uav_general_united_pub_sub_agent_req` | `uav_general_united_pub_sub_agent_rsp` | ★ |
| 00:A4 | 164 | `uav_general_model_auth_request` | `uav_general_model_auth_response` | ⛔ |
| 00:A5 | 165 | `uav_general_get_switch_upgrade_bin_req` | `uav_general_get_switch_upgrade_bin_rsp` | ⛔ |
| 00:A6 | 166 | `uav_general_get_gls_cp_status_req` | `uav_general_get_gls_cp_status_rsp` |  |
| 00:B2 | 178 | `uav_general_get_low_power_action_req` | `uav_general_get_low_power_action_rsp` | ⛔ |
| 00:B5 | 181 | `uav_general_get_exclusive_set_subscribe_req` | `uav_general_get_exclusive_set_subscribe_rsp` | ★ ⛔ |
| 00:B6 | 182 | `uav_general_get_exclusive_set_push_req` | `uav_general_get_exclusive_set_push_rsp` | ★ ⛔ |
| 00:B7 | 183 | `uav_general_get_static_cap_req` | `uav_general_get_static_cap_rsp` | ★ |
| 00:B8 | 184 | `uav_general_get_function_discover_req` | `uav_general_get_function_discover_rsp` | ★ |
| 00:D5 | 213 | `uav_general_get_lock_uav_req` | `uav_general_get_lock_uav_rsp` | ⛔ |
| 00:DA | 218 | `uav_general_get_data_act_req` | `uav_general_get_data_act_rsp` |  |
| 00:DD | 221 | `uav_general_get_UAV_CLOUD_CONTROL_req` | `uav_general_get_UAV_CLOUD_CONTROL_rsp` | ⛔ |
| 00:DE | 222 | `uav_general_DEVICE_RESET_req` | `uav_general_DEVICE_RESET_rsp` | ⛔ |
| 00:DF | 223 | `uav_general_log_space_control_req` | `uav_general_log_space_control_rsp` | ⛔ |
| 00:E5 | 229 | `uav_general_get_secure_binding_req` | `uav_general_get_secure_binding_rsp` | ⛔ |
| 00:E5 | 229 | `uav_general_get_secure_binding_rsp` | `` | ⛔ |
| 00:E6 | 230 | `uav_general_get_secure_device_user_bind_req` | `uav_general_get_secure_device_user_bind_rsp` | ⛔ |
| 00:E9 | 233 | `uav_general_add_log_tag_rsp` | `uav_general_add_log_tag_req` | ⛔ |
| 00:EA | 234 | `uav_general_log_export_control_req` | `uav_general_log_export_control_rsp` | ⛔ |
| 00:F4 | 244 | `uav_general_start_test_req` | `uav_general_start_test_rsp` | ⛔ |
| 00:FE | 254 | `uav_general_heartbeat_req` | `uav_general_heartbeat_rsp` | ★ |
| 00:FF | 255 | `uav_general_get_device_info_req` | `uav_general_get_device_info_rsp` | ★ |

### cmd_set 0x01: special

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 01:01 | 1 | `uav_special_special_ctrl_push` | `uav_special_special_ctrl_rsp` | ★ ⛔ |
| 01:02 | 2 | `uav_action_virtual_rc_joystick_req` | `uav_action_virtual_rc_joystick_rsp` | ⛔ |
| 01:0A | 10 | `uav_special_SPECIAL_TLV_CMD_push` | `uav_special_push_SPECIAL_TLV_CMD_rsp` | ★ |
| 01:82 | 130 | `uav_special_control_blackbox_folder_req` | `uav_special_control_blackbox_folder_rsp` | ⛔ |
| 01:83 | 131 | `uav_special_get_get_blackbox_info_req` | `uav_special_get_get_blackbox_info_rsp` | ⛔ |
| 01:84 | 132 | `uav_special_set_set_blackbox_info_req` | `uav_special_set_set_blackbox_info_rsp` | ⛔ |

### cmd_set 0x02: camera

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 02:01 | 1 | `uav_camera_take_photo_req` | `uav_camera_take_photo_rsp` | ⛔ |
| 02:02 | 2 | `uav_camera_record_video_req` | `uav_camera_record_video_rsp` | ⛔ |
| 02:09 | 9 | `uav_camera_set_liveview_source_camera_req` | `uav_camera_set_liveview_source_camera_rsp` | ⛔ |
| 02:0C | 12 | `uav_camera_switch_playbackmode_req` | `uav_camera_switch_playbackmode_rsp` | ⛔ |
| 02:10 | 16 | `uav_camera_set_camera_working_mode_req` | `uav_camera_set_camera_working_mode_rsp` | ⛔ |
| 02:12 | 18 | `uav_camera_set_camera_photo_size_req` | `uav_camera_set_camera_photo_size_rsp` | ⛔ |
| 02:14 | 20 | `uav_camera_set_camera_photo_quality_req` | `uav_camera_set_camera_photo_quality_rsp` | ⛔ |
| 02:16 | 22 | `uav_camera_set_camera_photo_storage_format_req` | `uav_camera_set_camera_photo_storage_format_rsp` | ⛔ |
| 02:18 | 24 | `uav_camera_set_video_format_req` | `uav_camera_set_video_format_rsp` | ⛔ |
| 02:1A | 26 | `uav_camera_set_camera_video_quality_req` | `uav_camera_set_camera_video_quality_rsp` | ⛔ |
| 02:1C | 28 | `uav_camera_set_camera_video_storage_format_req` | `uav_camera_set_camera_video_storage_format_rsp` | ⛔ |
| 02:1E | 30 | `uav_camera_set_camera_exposure_mode_req` | `uav_camera_set_camera_exposure_mode_rsp` | ⛔ |
| 02:20 | 32 | `uav_camera_set_camera_scene_mode_req` | `uav_camera_set_camera_scene_mode_rsp` | ⛔ |
| 02:21 | 33 | `uav_camera_get_camera_scene_mode_req` | `uav_camera_get_camera_scene_mode_rsp` | ⛔ |
| 02:22 | 34 | `uav_camera_set_camera_metering_mode_req` | `uav_camera_set_camera_metering_mode_rsp` | ⛔ |
| 02:24 | 36 | `uav_camera_set_camera_focus_mode_req` | `uav_camera_set_camera_focus_mode_rsp` | ⛔ |
| 02:26 | 38 | `uav_camera_set_aperture_size_req` | `uav_camera_set_aperture_size_rsp` | ⛔ |
| 02:28 | 40 | `uav_camera_set_camera_shutter_speed_req` | `uav_camera_set_camera_shutter_speed_rsp` | ⛔ |
| 02:29 | 41 | `uav_camera_get_camera_shutter_speed_req` | `uav_camera_get_camera_shutter_speed_rsp` |  |
| 02:2A | 42 | `uav_camera_set_camera_iso_para_req` | `uav_camera_set_camera_iso_para_rsp` | ⛔ |
| 02:2B | 43 | `uav_camera_get_camera_iso_para_req` | `uav_camera_get_camera_iso_para_rsp` |  |
| 02:2C | 44 | `uav_camera_set_camera_white_balance_req` | `uav_camera_set_camera_white_balance_rsp` | ⛔ |
| 02:2E | 46 | `uav_camera_set_camera_exposure_compensation_req` | `uav_camera_set_camera_exposure_compensation_rsp` | ⛔ |
| 02:30 | 48 | `uav_camera_set_focus_area_req` | `uav_camera_set_focus_area_rsp` | ⛔ |
| 02:32 | 50 | `uav_camera_set_spot_focus_area_req` | `uav_camera_set_spot_focus_area_rsp` | ⛔ |
| 02:33 | 51 | `uav_camera_get_spot_focus_area_req` | `uav_camera_get_spot_focus_area_rsp` |  |
| 02:34 | 52 | `uav_camera_set_focus_zoom_para_req` | `uav_camera_set_focus_zoom_para_rsp` | ⛔ |
| 02:38 | 56 | `uav_camera_set_sharpness_para_req` | `uav_camera_set_sharpness_para_rsp` | ⛔ |
| 02:3A | 58 | `uav_camera_set_contrast_para_req` | `uav_camera_set_contrast_para_rsp` | ⛔ |
| 02:3C | 60 | `uav_camera_set_saturation_para_req` | `uav_camera_set_saturation_para_rsp` | ⛔ |
| 02:3E | 62 | `uav_camera_set_colortone_para_req` | `uav_camera_set_colortone_para_rsp` | ⛔ |
| 02:42 | 66 | `uav_camera_set_digital_filter_req` | `uav_camera_set_digital_filter_rsp` | ⛔ |
| 02:44 | 68 | `uav_camera_set_digital_denoising_req` | `uav_camera_set_digital_denoising_rsp` | ⛔ |
| 02:46 | 70 | `uav_camera_set_anti_filcker_req` | `uav_camera_set_anti_filcker_rsp` | ⛔ |
| 02:48 | 72 | `uav_camera_set_continue_para_req` | `uav_camera_set_continue_para_rsp` | ⛔ |
| 02:4A | 74 | `uav_camera_set_timelapse_para_req` | `uav_camera_set_timelapse_para_rsp` | ⛔ |
| 02:4B | 75 | `uav_camera_get_timelapse_para_req` | `uav_camera_get_timelapse_para_rsp` |  |
| 02:4C | 76 | `uav_camera_set_video_out_para_req` | `uav_camera_set_video_out_para_rsp` | ⛔ |
| 02:4D | 77 | `uav_camera_get_video_out_para_req` | `uav_camera_get_video_out_para_rsp` |  |
| 02:54 | 84 | `uav_camera_set_date_para_req` | `uav_camera_set_date_para_rsp` | ⛔ |
| 02:56 | 86 | `uav_camera_set_language_para_req` | `uav_camera_set_language_para_rsp` | ⛔ |
| 02:57 | 87 | `uav_camera_get_language_para_req` | `uav_camera_get_language_para_rsp` |  |
| 02:58 | 88 | `uav_camera_set_gps_coordinate_req` | `uav_camera_set_gps_coordinate_rsp` | ★ ⛔ |
| 02:59 | 89 | `uav_camera_get_gps_coordinate_req` | `uav_camera_get_gps_coordinate_rsp` | ★ |
| 02:5C | 92 | `uav_camera_set_file_index_mode_req` | `uav_camera_set_file_index_mode_rsp` | ⛔ |
| 02:5E | 94 | `uav_camera_set_aeb_continues_req` | `uav_camera_set_aeb_continues_rsp` | ⛔ |
| 02:5F | 95 | `uav_camera_get_aeb_continues_req` | `uav_camera_get_aeb_continues_rsp` |  |
| 02:60 | 96 | `uav_camera_set_histogram_push_enable_req` | `uav_camera_set_histogram_push_enable_rsp` | ★ ⛔ |
| 02:61 | 97 | `uav_camera_get_histogram_push_enable_req` | `uav_camera_get_histogram_push_enable_rsp` | ★ |
| 02:62 | 98 | `uav_camera_set_video_caption_req` | `uav_camera_set_video_caption_rsp` | ⛔ |
| 02:63 | 99 | `uav_camera_get_video_caption_req` | `uav_camera_get_video_caption_rsp` |  |
| 02:66 | 102 | `uav_camera_set_ntspal_type_req` | `uav_camera_set_ntspal_type_rsp` | ⛔ |
| 02:68 | 104 | `uav_camera_set_ae_lock_req` | `uav_camera_set_ae_lock_rsp` | ⛔ |
| 02:69 | 105 | `uav_camera_get_ae_lock_req` | `uav_camera_get_ae_lock_rsp` | ⛔ |
| 02:6A | 106 | `uav_camera_set_capture_type_req` | `uav_camera_set_capture_type_rsp` | ⛔ |
| 02:6C | 108 | `uav_camera_set_recording_mode_req` | `uav_camera_set_recording_mode_rsp` | ⛔ |
| 02:6E | 110 | `uav_camera_set_pano_mode_req` | `uav_camera_set_pano_mode_rsp` | ⛔ |
| 02:6F | 111 | `uav_camera_get_pano_mode_req` | `uav_camera_get_pano_mode_rsp` | ⛔ |
| 02:72 | 114 | `uav_camera_format_sdcard_req` | `uav_camera_format_sdcard_rsp` | ⛔ |
| 02:77 | 119 | `uav_camera_save_camera_para_req` | `uav_camera_save_camera_para_rsp` |  |
| 02:78 | 120 | `uav_camera_load_camera_para_req` | `uav_camera_load_camera_para_rsp` |  |
| 02:79 | 121 | `uav_camera_delete_photo_req` | `uav_camera_delete_photo_rsp` | ⛔ |
| 02:7A | 122 | `uav_camera_video_playback_control_req` | `uav_camera_video_playback_control_rsp` | ⛔ |
| 02:7B | 123 | `uav_camera_single_playback_select_req` | `uav_camera_single_playback_select_rsp` |  |
| 02:8E | 142 | `uav_camera_parameter_option_req` | `uav_camera_parameter_option_rsp` |  |
| 02:8E | 142 | `uav_camera_parameter_option_rsp` | `` |  |
| 02:8F | 143 | `uav_camera_push_settings_update_notify_rsp` | `uav_camera_settings_update_notify_push` | ★ |
| 02:90 | 144 | `uav_camera_serial_number_req` | `uav_camera_serial_number_rsp` |  |
| 02:92 | 146 | `uav_camera_get_video_recording_info_req` | `uav_camera_get_video_recording_info_rsp` | ⛔ |
| 02:95 | 149 | `uav_camera_set_focus_engine_value_req` | `uav_camera_set_focus_engine_value_rsp` | ⛔ |
| 02:9F | 159 | `uav_camera_set_audio_param_req` | `uav_camera_set_audio_param_rsp` | ⛔ |
| 02:A0 | 160 | `uav_camera_get_audio_param_req` | `uav_camera_get_audio_param_rsp` |  |
| 02:A2 | 162 | `uav_camera_set_lens_focal_distance_req` | `uav_camera_set_lens_focal_distance_rsp` | ⛔ |
| 02:A3 | 163 | `uav_camera_set_calibration_control_req` | `uav_camera_set_calibration_control_rsp` | ⛔ |
| 02:A8 | 168 | `uav_camera_set_ae_lock_type_req` | `uav_camera_set_ae_lock_type_rsp` | ⛔ |
| 02:AB | 171 | `uav_camera_set_video_coding_standard_req` | `uav_camera_set_video_coding_standard_rsp` | ⛔ |
| 02:AF | 175 | `uav_camera_set_pro_video_format_req` | `uav_camera_set_pro_video_format_rsp` | ⛔ |
| 02:B0 | 176 | `uav_camera_get_pro_video_format_req` | `uav_camera_get_pro_video_format_rsp` | ⛔ |
| 02:B3 | 179 | `uav_camera_get_app_request_i_frame_req` | `uav_camera_get_app_request_i_frame_rsp` | ★ |
| 02:B5 | 181 | `uav_camera_get_sensor_id_req` | `uav_camera_get_sensor_id_rsp` |  |
| 02:B6 | 182 | `uav_camera_set_front_led_auto_close_req` | `uav_camera_set_front_led_auto_close_rsp` | ⛔ |
| 02:B8 | 184 | `uav_camera_set_control_zoom_req` | `uav_camera_set_control_zoom_rsp` | ⛔ |
| 02:B9 | 185 | `uav_camera_set_image_orientation_req` | `uav_camera_set_image_orientation_rsp` | ⛔ |
| 02:BB | 187 | `uav_camera_set_lock_gimbal_when_capture_req` | `uav_camera_set_lock_gimbal_when_capture_rsp` | ⛔ |
| 02:BF | 191 | `uav_camera_set_file_tag_req` | `uav_camera_set_file_tag_rsp` | ⛔ |
| 02:C4 | 196 | `uav_camera_set_tap_zoom_enable_req` | `uav_camera_set_tap_zoom_enable_rsp` | ⛔ |
| 02:C5 | 197 | `uav_camera_get_tap_zoom_enable_req` | `uav_camera_get_tap_zoom_enable_rsp` |  |
| 02:C6 | 198 | `uav_camera_set_tap_zoom_target_req` | `uav_camera_set_tap_zoom_target_rsp` | ⛔ |
| 02:CE | 206 | `uav_camera_get_calibration_control_req` | `uav_camera_get_calibration_control_rsp` | ⛔ |
| 02:D7 | 215 | `uav_camera_set_user_custom_data_req` | `uav_camera_set_user_custom_data_rsp` | ⛔ |
| 02:D8 | 216 | `uav_camera_get_user_custom_data_req` | `uav_camera_get_user_custom_data_rsp` |  |
| 02:DA | 218 | `uav_camera_storage_config_req` | `uav_camera_storage_config_rsp` |  |
| 02:E1 | 225 | `uav_camera_set_set_mode_profile_req` | `uav_camera_set_set_mode_profile_rsp` | ⛔ |
| 02:E5 | 229 | `uav_camera_set_watermark_req` | `uav_camera_set_watermark_rsp` | ⛔ |
| 02:E7 | 231 | `uav_camera_set_original_photo_saved_configuration_req` | `uav_camera_set_original_photo_saved_configuration_rsp` | ⛔ |
| 02:E8 | 232 | `uav_camera_get_original_photo_saved_configuration_req` | `uav_camera_get_original_photo_saved_configuration_rsp` |  |
| 02:EB | 235 | `uav_camera_set_camera_status_subscribe_req` | `uav_camera_set_camera_status_subscribe_rsp` | ★ ⛔ |
| 02:FE | 254 | `uav_camera_set_set_baseband_req` | `uav_camera_set_set_baseband_rsp` | ⛔ |
| 02:FF | 255 | `uav_camera_cam_expan_cmd` | `uav_camera_camera_expansion_cmd_rsp` |  |

### cmd_set 0x03: flight controller

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 03:2A | 42 | `uav_fc_blade_calibration_req` | `uav_fc_function_control_rsp` | ⛔ |
| 03:2A | 42 | `uav_fc_function_control_req` | `uav_fc_function_control_rsp` | ⛔ |
| 03:2F | 47 | `uav_fc_set_voltage_alert_req` | `uav_fc_set_voltage_alert_rsp` | ⛔ |
| 03:2F | 47 | `uav_voltage_alert_parameter` | `uav_fc_set_voltage_alert_rsp` |  |
| 03:30 | 48 | `uav_fc_get_voltage_alert_req` | `uav_fc_get_voltage_alert_rsp` |  |
| 03:31 | 49 | `uav_fc_set_homepoint_req` | `uav_fc_set_homepoint_rsp` | ⛔ |
| 03:33 | 51 | `uav_fc_set_aircraft_name_req` | `uav_fc_set_aircraft_name_rsp` | ⛔ |
| 03:34 | 52 | `uav_fc_get_aircraft_name_req` | `uav_fc_get_aircraft_name_rsp` |  |
| 03:39 | 57 | `uav_fc_switch_to_read_data_mode_req` | `uav_fc_switch_to_read_data_mode_rsp` | ⛔ |
| 03:3B | 59 | `uav_fc_set_fail_safe_action_req` | `uav_fc_set_fail_safe_action_rsp` | ⛔ |
| 03:3C | 60 | `uav_fc_get_fail_safe_action_req` | `uav_fc_get_fail_safe_action_rsp` | ⛔ |
| 03:46 | 70 | `uav_fc_switch_gps_snr_push_req` | `uav_fc_switch_gps_snr_push_rsp` | ★ ⛔ |
| 03:52 | 82 | `uav_fc_confirm_electricity_gohome_req` | `uav_fc_confirm_electricity_gohome_rsp` | ★ |
| 03:5B | 91 | `uav_fc_capability_set_subscribe_push` | `uav_fc_push_capability_set_subscribe_rsp` | ★ ⛔ |
| 03:5C | 92 | `uav_fc_capability_set_push_push` | `uav_fc_push_capability_set_push_rsp` | ★ ⛔ |
| 03:77 | 119 | `uav_fc_handle_eid_switch` | `uav_fc_eid_switch_status` | ⛔ |
| 03:78 | 120 | `uav_fc_action_rid_set_and_delete_opid` | `uav_fc_action_rid_set_and_delete_opid_ack` | ⛔ |
| 03:80 | 128 | `uav_fc_set_ground_station_on_off_req` | `uav_fc_set_ground_station_on_off_rsp` | ⛔ |
| 03:8F | 143 | `uav_fc_recorder_rpc_rsp` | `uav_fc_recorder_rpc_req` | ⛔ |
| 03:9C | 156 | `uav_fc_set_waypoint_auto_flight_speed_req` | `uav_fc_set_waypoint_auto_flight_speed_rsp` | ⛔ |
| 03:9D | 157 | `uav_fc_get_waypoint_auto_flight_speed_req` | `uav_fc_get_waypoint_auto_flight_speed_rsp` | ⛔ |
| 03:A0 | 160 | `uav_fc_agnss_pos_and_time_data_push` | `uav_fc_push_agnss_pos_and_time_data_rsp` | ★ ⛔ |
| 03:A2 | 162 | `uav_fc_agps_online_push_push` | `uav_fc_push_agps_online_push_rsp` | ★ ⛔ |
| 03:AF | 175 | `uav_fc_get_product_config_req` | `uav_fc_get_product_config_rsp` | ★ |
| 03:B4 | 180 | `uav_fc_get_uav_uav_code_req` | `uav_fc_get_uav_uav_code_rsp` |  |
| 03:B8 | 184 | `uav_fc_get_redundancy_system_req` | `uav_fc_get_redundancy_system_rsp` |  |
| 03:BB | 187 | `uav_fc_get_nfzdb_upgrade_status_query_req` | `uav_fc_get_nfzdb_upgrade_status_query_rsp` | ⛔ |
| 03:BC | 188 | `uav_fc_fmu_api_register_led_action_req` | `uav_fc_fmu_api_register_led_action_rsp` | ⛔ |
| 03:BC | 188 | `uav_fc_get_nfzdb_upgrade_result_query_req` | `uav_fc_get_nfzdb_upgrade_result_query_rsp` | ⛔ |
| 03:BD | 189 | `uav_fc_fmu_api_logout_led_action_req` | `uav_fc_fmu_api_logout_led_action_rsp` | ⛔ |
| 03:BD | 189 | `uav_fc_nfz_upgrade_exit_req` | `uav_fc_nfz_upgrade_exit_rsp` | ⛔ |
| 03:BE | 190 | `uav_fc_fmu_api_set_led_action_req` | `uav_fc_fmu_api_set_led_action_rsp` | ⛔ |
| 03:D7 | 215 | `uav_fc_recorder_rpc_rsp` | `uav_fc_recorder_rpc_req` | ⛔ |
| 03:DA | 218 | `uav_fc_mc_monitor_req` | `uav_fc_mc_monitor_rsp` | ★ |
| 03:E9 | 233 | `uav_fc_set_cmd_handler_req` | `uav_fc_set_cmd_handler_rsp` | ⛔ |
| 03:ED | 237 | `uav_fc_esc_echo_cmd_info_req` | `uav_fc_esc_echo_cmd_info_rsp` | ⛔ |
| 03:EE | 238 | `uav_fc_get_app_count_down_push_req` | `uav_general_set_device_date_rsp` | ★ |
| 03:F3 | 243 | `uav_fc_reset_cfg_item_req` | `uav_fc_reset_cfg_item_rsp` | ⛔ |
| 03:F5 | 245 | `uav_fc_get_get_set_driver_licesen_info_req` | `uav_fc_get_get_set_driver_licesen_info_rsp` | ⛔ |
| 03:F7 | 247 | `uav_fc_get_get_cfg_item_info_by_hash_req` | `uav_fc_get_get_cfg_item_info_by_hash_rsp` |  |
| 03:F8 | 248 | `uav_fc_read_hash_param_req` | `uav_fc_read_hash_param_rsp` |  |
| 03:F9 | 249 | `uav_fc_set_write_hash_param_req` | `uav_fc_set_write_hash_param_rsp` | ⛔ |
| 03:FA | 250 | `uav_fc_set_reset_cfg_item_by_hash_req` | `uav_fc_set_reset_cfg_item_by_hash_rsp` | ⛔ |
| 03:FE | 254 | `uav_fc_set_set_motor_force_disable_flag_req` | `uav_fc_set_set_motor_force_disable_flag_rsp` | ⛔ |

### cmd_set 0x04: gimbal

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 04:01 | 1 | `uav_gimbal_set_motion_control_req` | `uav_gimbal_set_motion_control_rsp` | ⛔ |
| 04:07 | 7 | `uav_gimbal_set_roll_trimming_adjust_req` | `uav_gimbal_set_roll_trimming_adjust_rsp` | ⛔ |
| 04:08 | 8 | `uav_gimbal_auto_calibration_req` | `uav_gimbal_auto_calibration_rsp` | ⛔ |
| 04:0A | 10 | `uav_gimbal_set_control_gimbal_angle_req` | `uav_gimbal_set_control_gimbal_angle_rsp` | ⛔ |
| 04:0C | 12 | `uav_gimbal_set_cmd_custom_ctrl_speed_req` | `uav_gimbal_set_cmd_custom_ctrl_speed_rsp` | ⛔ |
| 04:0D | 13 | `uav_gimbal_set_turn_on_off_control_req` | `uav_gimbal_set_turn_on_off_control_rsp` | ⛔ |
| 04:0F | 15 | `uav_gimbal_set_user_params_req` | `uav_gimbal_set_user_params_rsp` | ⛔ |
| 04:10 | 16 | `uav_gimbal_read_params_req` | `uav_gimbal_read_params_rsp` |  |
| 04:12 | 18 | `uav_gimbal_get_message_subscription_req` | `uav_gimbal_get_message_subscription_rsp` | ★ |
| 04:13 | 19 | `uav_gimbal_reset_default_params_req` | `uav_gimbal_reset_default_params_rsp` | ⛔ |
| 04:14 | 20 | `uav_gimbal_set_control_gimbal_angle_ex_req` | `uav_gimbal_set_control_gimbal_angle_ex_rsp` | ⛔ |
| 04:25 | 37 | `uav_gimbal_set_gimbal_timelapse_control_req` | `uav_gimbal_set_gimbal_timelapse_control_rsp` | ⛔ |
| 04:3A | 58 | `uav_gimbal_set_coordinate_system_rotate_req` | `uav_gimbal_set_coordinate_system_rotate_rsp` | ⛔ |
| 04:44 | 68 | `uav_gimbal_set_gimbal_work_mode_req` | `uav_gimbal_set_gimbal_work_mode_rsp` | ⛔ |
| 04:4C | 76 | `uav_gimbal_set_work_mode_and_return_center_req` | `uav_gimbal_set_work_mode_and_return_center_rsp` | ⛔ |
| 04:50 | 80 | `uav_gimbal_gimbal_system_param_req` | `uav_gimbal_gimbal_system_param_rsp` |  |
| 04:67 | 103 | `uav_gimbal_set_gimbal_esc_extern_command_req` | `uav_gimbal_set_gimbal_esc_extern_command_rsp` | ⛔ |
| 04:68 | 104 | `uav_gimbal_cali_data_exist_req` | `uav_gimbal_cali_data_exist_rsp` |  |
| 04:72 | 114 | `uav_gimbal_get_get_gimbal_info_extend_req` | `uav_gimbal_get_get_gimbal_info_extend_rsp` |  |
| 04:77 | 119 | `uav_gimbal_get_gimbal_capability_req` | `uav_gimbal_get_gimbal_capability_rsp` |  |

### cmd_set 0x05: center board

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 05:08 | 8 | `uav_centerboard_get_request_battery_history_state_req` | `uav_centerboard_get_request_battery_history_state_rsp` | ★ |
| 05:09 | 9 | `uav_centerboard_battery_self_discharge_req` | `uav_centerboard_battery_self_discharge_rsp` | ★ ⛔ |
| 05:21 | 33 | `uav_centerboard_get_request_battery_static_info_req` | `uav_centerboard_get_request_battery_static_info_rsp` | ★ |
| 05:33 | 51 | `uav_centerboard_get_get_battery_barcode_req` | `uav_centerboard_get_get_battery_barcode_rsp` | ★ |

### cmd_set 0x06: remote controller

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 06:03 | 3 | `uav_rc_calibrate_channels_req` | `uav_rc_calibrate_channels_rsp` | ⛔ |
| 06:06 | 6 | `uav_rc_set_machine_mode_req` | `uav_rc_set_machine_mode_rsp` | ⛔ |
| 06:07 | 7 | `uav_rc_get_machine_mode_req` | `uav_rc_get_machine_mode_rsp` | ⛔ |
| 06:0A | 10 | `uav_rc_set_local_machine_password_req` | `uav_rc_set_local_machine_password_rsp` | ⛔ |
| 06:0B | 11 | `uav_rc_get_local_machine_password_req` | `uav_rc_get_local_machine_password_rsp` | ⛔ |
| 06:11 | 17 | `uav_rc_set_machine_function_switch_req` | `uav_rc_set_machine_function_switch_rsp` | ⛔ |
| 06:12 | 18 | `uav_rc_get_machine_function_switch_req` | `uav_rc_get_machine_function_switch_rsp` | ⛔ |
| 06:19 | 25 | `uav_rc_set_controller_mode_req` | `uav_rc_set_controller_mode_rsp` | ⛔ |
| 06:1A | 26 | `uav_rc_get_controller_mode_req` | `uav_rc_get_controller_mode_rsp` | ⛔ |
| 06:21 | 33 | `uav_rc_get_ce_fcc_req` | `uav_rc_get_ce_fcc_rsp` |  |
| 06:22 | 34 | `uav_rc_get_gimbal_control_req` | `uav_rc_get_gimbal_control_rsp` | ⛔ |
| 06:23 | 35 | `uav_rc_request_gimbal_control_rsp` | `` | ⛔ |
| 06:2A | 42 | `uav_rc_get_slave_control_mode_req` | `uav_rc_get_slave_control_mode_rsp` | ⛔ |
| 06:2C | 44 | `uav_rc_get_gimbal_control_speed_req` | `uav_rc_get_gimbal_control_speed_rsp` | ⛔ |
| 06:2D | 45 | `uav_rc_set_customized_btn_function_req` | `uav_rc_set_customized_btn_function_rsp` | ⛔ |
| 06:2E | 46 | `uav_rc_get_customized_btn_function_req` | `uav_rc_get_customized_btn_function_rsp` |  |
| 06:2F | 47 | `uav_rc_pair_frequency_req` | `uav_rc_pair_frequency_rsp` | ⛔ |
| 06:32 | 50 | `uav_rc_get_rtc_clock_req` | `uav_rc_get_rtc_clock_rsp` | ⛔ |
| 06:34 | 52 | `uav_rc_get_gimbal_control_gain_req` | `uav_rc_get_gimbal_control_gain_rsp` | ⛔ |
| 06:36 | 54 | `uav_rc_get_gimbal_control_mode_req` | `uav_rc_get_gimbal_control_mode_rsp` | ⛔ |
| 06:3A | 58 | `uav_rc_set_usb_mode_2014rc_req` | `uav_rc_set_usb_mode_2014rc_rsp` | ⛔ |
| 06:3D | 61 | `uav_rc_mutil_device_pair_t20_req` | `uav_rc_mutil_device_pair_rsp` | ⛔ |
| 06:46 | 70 | `uav_rc_mutil_device_select_target_aircraft_req` | `uav_rc_mutil_device_select_target_aircraft_rsp` |  |
| 06:47 | 71 | `uav_rc_custom_function_control_req` | `uav_rc_custom_function_control_rsp` | ⛔ |
| 06:48 | 72 | `uav_rc_param_request_req` | `uav_rc_param_request_rsp` |  |
| 06:49 | 73 | `uav_rc_mutil_device_enable_rtk_req` | `uav_rc_mutil_device_enable_rtk_rsp` |  |
| 06:4A | 74 | `uav_rc_mutil_device_enable_4g_req` | `uav_rc_mutil_device_enable_4g_rsp` |  |
| 06:53 | 83 | `uav_rc_get_unit_language_req` | `uav_rc_get_unit_language_rsp` |  |
| 06:54 | 84 | `uav_rc_set_unit_language_req` | `uav_rc_set_unit_language_rsp` | ⛔ |
| 06:59 | 89 | `uav_rc_set_set_pts_channel_req` | `uav_rc_set_set_pts_channel_rsp` | ⛔ |
| 06:6B | 107 | `uav_rc_UAV_RACING_RC_VIBRATING_MOTOR_CTRL_push` | `uav_rc_push_UAV_RACING_RC_VIBRATING_MOTOR_CTRL_rsp` | ★ ⛔ |
| 06:72 | 114 | `uav_rc_set_stick_value_lock_req` | `uav_rc_set_stick_value_lock_rsp` | ⛔ |
| 06:72 | 114 | `uav_rc_set_stick_value_lock_with_ch4_func_req` | `uav_rc_set_stick_value_lock_rsp` | ⛔ |
| 06:74 | 116 | `uav_rc_get_stick_value_lock_status_req` | `uav_rc_get_stick_value_lock_status_with_ch4_func_rsp` | ⛔ |
| 06:79 | 121 | `uav_rc_get_get_rc_firmware_info_req` | `uav_rc_get_get_rc_firmware_info_rsp` |  |
| 06:8C | 140 | `uav_rc_set_app_work_stage_set_req` | `uav_rc_set_app_work_stage_set_rsp` | ★ ⛔ |
| 06:8D | 141 | `uav_rc_set_self_def_key_list_req` | `uav_rc_set_self_def_key_rsp` | ⛔ |
| 06:8E | 142 | `uav_rc_get_self_def_key_list_req` | `uav_rc_get_self_def_key_list_rsp` |  |
| 06:A1 | 161 | `uav_rc_push_data_sync_rsp` | `` | ★ |
| 06:AA | 170 | `uav_rc_rocker_control_gimbal_mode_req` | `uav_rc_rocker_control_gimbal_mode_rsp` | ⛔ |
| 06:E5 | 229 | `uav_rc_get_custom_setting_support_info_req` | `uav_rc_get_custom_setting_support_info_rsp` |  |
| 06:F1 | 241 | `uav_rc_set_app_to_pc_control_req` | `uav_rc_set_app_to_pc_control_rsp` | ★ ⛔ |

### cmd_set 0x07: wifi

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 07:05 | 5 | `uav_wifi_set_ap_power_req` | `uav_wifi_set_ap_power_rsp` | ⛔ |
| 07:06 | 6 | `uav_wifi_get_ap_power_req` | `uav_wifi_get_ap_power_rsp` | ⛔ |
| 07:07 | 7 | `uav_wifi_get_ssid_req` | `uav_wifi_get_ssid_rsp` | ⛔ |
| 07:08 | 8 | `uav_wifi_set_ssid_req` | `uav_wifi_set_ssid_rsp` | ⛔ |
| 07:0C | 12 | `uav_wifi_get_mac_req` | `uav_wifi_get_mac_rsp` |  |
| 07:0D | 13 | `uav_wifi_set_password_req` | `uav_wifi_set_password_rsp` | ⛔ |
| 07:0E | 14 | `uav_wifi_get_password_req` | `uav_wifi_get_password_rsp` | ⛔ |
| 07:10 | 16 | `uav_wifi_set_frequency_switch_req` | `uav_wifi_set_frequency_switch_rsp` | ⛔ |
| 07:15 | 21 | `uav_wifi_restart_req` | `uav_wifi_restart_rsp` | ⛔ |
| 07:16 | 22 | `uav_wifi_set_auto_freq_req` | `uav_wifi_set_auto_freq_rsp` | ⛔ |
| 07:17 | 23 | `uav_wifi_get_auto_freq_req` | `uav_wifi_get_auto_freq_rsp` |  |
| 07:18 | 24 | `uav_wifi_set_country_code_req` | `uav_wifi_set_country_code_rsp` | ⛔ |
| 07:19 | 25 | `uav_wifi_get_country_code_req` | `uav_wifi_get_country_code_rsp` | ⛔ |
| 07:28 | 40 | `uav_wifi_get_sdr_channel_info_req` | `uav_wifi_get_sdr_channel_info_rsp` | ★ |
| 07:29 | 41 | `uav_wifi_request_snr_req` | `uav_wifi_request_snr_rsp` | ★ |
| 07:2B | 43 | `uav_wifi_set_wifi_frequecy_req` | `uav_wifi_set_ssid_rsp` | ⛔ |
| 07:2E | 46 | `uav_wifi_set_frequency_support_req` | `uav_wifi_set_frequency_support_rsp` | ⛔ |
| 07:30 | 48 | `uav_wifi_set_country_code_ext_req` | `uav_wifi_set_country_code_ext_rsp` | ⛔ |
| 07:33 | 51 | `uav_wifi_get_is_support_area_code_req` | `uav_wifi_get_is_support_area_code_rsp` |  |
| 07:41 | 65 | `uav_wifi_start_ground_wifi_req` | `uav_wifi_start_ground_wifi_rsp` | ⛔ |
| 07:42 | 66 | `uav_wifi_stop_ground_wifi_req` | `uav_wifi_stop_ground_wifi_rsp` | ⛔ |
| 07:44 | 68 | `uav_wifi_get_get_frequency_req` | `uav_wifi_get_get_frequency_rsp` | ⛔ |
| 07:45 | 69 | `uav_wifi_device_permission_verification_req` | `uav_wifi_device_permission_verification_rsp` | ★ ⛔ |
| 07:46 | 70 | `uav_wifi_push_device_permission_verification_asyn_result_rsp` | `` | ★ ⛔ |
| 07:47 | 71 | `uav_wifi_connect_ap_req` | `uav_wifi_connect_ap_rsp` |  |
| 07:93 | 147 | `uav_wifi_sw_dev_info_1_push` | `uav_wifi_request_snr_rsp` | ★ |
| 07:93 | 147 | `uav_wifi_sw_dev_info_push` | `uav_wifi_request_snr_rsp` | ★ |
| 07:B7 | 183 | `uav_wifi_silent_backhaul_device_pairing_action_req` | `uav_wifi_silent_backhaul_device_pairing_action_rsp` | ⛔ |
| 07:BA | 186 | `uav_wifi_device_capability_nego_req` | `uav_wifi_device_capability_nego_rsp` | ★ |

### cmd_set 0x08: dm368 / video ground

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 08:01 | 1 | `uav_dm368_set_ground_side_param_req` | `uav_dm368_set_ground_side_param_rsp` | ⛔ |
| 08:02 | 2 | `uav_dm368_read_ground_side_param_req` | `uav_dm368_read_ground_side_param_rsp` |  |
| 08:32 | 50 | `uav_dm368_sdr_data_report_push_push` | `uav_dm368_push_sdr_data_report_push_rsp` | ★ |
| 08:41 | 65 | `uav_dm368_send_decode_capability_req` | `uav_dm368_send_decode_capability_rsp` |  |
| 08:42 | 66 | `uav_dm368_action_send_decode_framerate_ability_req` | `uav_dm368_action_send_decode_framerate_ability_rsp` | ⛔ |
| 08:43 | 67 | `uav_dm368_set_auto_framerate_state_req` | `uav_dm368_set_auto_framerate_state_rsp` | ⛔ |
| 08:69 | 105 | `uav_dm368_set_liveview_priority_bandwidth_req` | `uav_dm368_set_liveview_priority_bandwidth_rsp` | ⛔ |
| 08:78 | 120 | `uav_dm368_set_sh_start_live_streaming_req` | `uav_dm368_set_sh_start_live_streaming_rsp` | ⛔ |
| 08:79 | 121 | `uav_dm368_get_sh_get_live_streaming_setting_info_req` | `uav_dm368_get_sh_get_live_streaming_setting_info_rsp` |  |

### cmd_set 0x09: ofdm / hd-link

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 09:09 | 9 | `uav_ofdm_frequency_power_push_request_req` | `uav_ofdm_frequency_power_push_request_rsp` | ★ ⛔ |
| 09:0D | 13 | `uav_ofdm_set_config_info_req` | `uav_ofdm_set_config_info_rsp` | ★ ⛔ |
| 09:21 | 33 | `uav_ofdm_get_sdr_conf_req` | `uav_ofdm_get_sdr_conf_rsp` | ★ |
| 09:26 | 38 | `uav_ofdm_read_sdr_param_req` | `uav_ofdm_read_sdr_param_rsp` | ★ |
| 09:27 | 39 | `uav_ofdm_set_sdr_param_req` | `uav_ofdm_set_sdr_param_rsp` | ★ ⛔ |
| 09:39 | 57 | `uav_ofdm_set_sdr_config_info_req` | `uav_ofdm_set_sdr_config_info_rsp` | ★ ⛔ |
| 09:44 | 68 | `uav_ofdm_sdr_role_revert_req` | `uav_ofdm_sdr_role_revert_rsp` | ★ ⛔ |
| 09:4B | 75 | `device_ofdm_sdr_dongle_state_req` | `device_ofdm_sdr_dongle_state_rsp` | ★ |
| 09:4D | 77 | `uav_ofdm_get_hdvt_mode_get_req` | `uav_ofdm_get_hdvt_mode_get_rsp` | ★ ⛔ |
| 09:4E | 78 | `uav_ofdm_set_hdvt_mode_switch_req` | `uav_ofdm_set_hdvt_mode_switch_rsp` | ★ ⛔ |
| 09:A0 | 160 | `uav_ofdm_get_sssfn_req` | `uav_ofdm_get_sssfn_rsp` | ★ |
| 09:B3 | 179 | `uav_ofdm_set_selete_fpv_req` | `uav_ofdm_set_selete_fpv_rsp` | ★ ⛔ |
| 09:F9 | 249 | `uav_ofdm_RELAY_FREQ_PEER_START_req` | `uav_ofdm_RELAY_FREQ_PEER_START_rsp` | ★ ⛔ |
| 09:FA | 250 | `uav_ofdm_RELAY_FUNC_req` | `uav_ofdm_RELAY_FUNC_rsp` | ★ ⛔ |
| 09:FD | 253 | `uav_ofdm_gnd_decoder_ability_feedback_push` | `uav_ofdm_push_gnd_decoder_ability_feedback_rsp` | ★ |

### cmd_set 0x0A: vision

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 0A:09 | 9 | `uav_vision_set_debug_upload_req` | `uav_vision_set_debug_upload_rsp` | ⛔ |
| 0A:1B | 27 | `uav_vision_free_pano_cap_area_info_push` | `uav_vision_push_free_pano_cap_area_info_rsp` | ★ |
| 0A:20 | 32 | `uav_vision_set_tracking_select_req` | `uav_vision_set_tracking_select_rsp` | ⛔ |
| 0A:27 | 39 | `uav_vision_set_common_ctrl_req` | `uav_vision_set_common_ctrl_rsp` | ⛔ |
| 0A:28 | 40 | `uav_vision_get_get_param_req` | `uav_vision_get_get_param_rsp` |  |
| 0A:29 | 41 | `uav_vision_set_set_param_req` | `uav_vision_set_set_param_rsp` | ⛔ |
| 0A:3E | 62 | `uav_vision_set_pano_control_req` | `uav_vision_set_pano_control_rsp` | ⛔ |
| 0A:4A | 74 | `uav_vision_set_action_cmd_req` | `uav_vision_set_action_cmd_rsp` | ⛔ |
| 0A:56 | 86 | `uav_vision_set_set_perception_switch_cmds_req` | `uav_vision_set_set_perception_switch_cmds_rsp` | ⛔ |
| 0A:58 | 88 | `uav_vision_get_get_perception_switch_cmds_req` | `uav_vision_get_get_perception_switch_cmds_rsp` | ⛔ |
| 0A:5B | 91 | `uav_vision_set_switch_navigation_function_req` | `uav_vision_set_switch_navigation_function_rsp` | ⛔ |
| 0A:5C | 92 | `uav_vision_set_switch_fixed_speed_req` | `uav_vision_set_switch_fixed_speed_rsp` | ⛔ |
| 0A:62 | 98 | `uav_vision_set_visual_stablize_app_state_req` | `uav_vision_set_visual_stablize_app_state_rsp` | ★ ⛔ |
| 0A:74 | 116 | `uav_vision_set_time_lapse_submode_req` | `uav_vision_set_time_lapse_submode_rsp` | ⛔ |
| 0A:74 | 116 | `uav_vision_set_time_lapse_submode_req_v1` | `uav_vision_set_time_lapse_submode_rsp` | ⛔ |
| 0A:76 | 118 | `uav_vision_set_time_lapse_waypoint_record_action_req` | `uav_vision_set_time_lapse_waypoint_record_action_rsp` | ⛔ |
| 0A:77 | 119 | `uav_vision_get_time_lapse_waypoint_download_req` | `uav_vision_get_time_lapse_waypoint_download_rsp` | ⛔ |
| 0A:78 | 120 | `uav_vision_set_time_lapse_start_req` | `uav_vision_set_time_lapse_start_rsp` | ⛔ |
| 0A:7A | 122 | `uav_vision_set_time_lapse_pause_stop_req` | `uav_vision_set_time_lapse_pause_stop_rsp` | ⛔ |
| 0A:7B | 123 | `uav_vision_set_time_lapse_set_param_req` | `uav_vision_set_time_lapse_set_param_rsp` | ⛔ |
| 0A:7C | 124 | `uav_vision_set_time_lapse_load_task_req` | `uav_vision_set_time_lapse_load_task_rsp` | ⛔ |
| 0A:7D | 125 | `uav_vision_set_app_camera_calibration_cmd_req` | `uav_vision_set_app_camera_calibration_cmd_rsp` | ★ ⛔ |
| 0A:81 | 129 | `uav_vision_set_start_stop_uav_req` | `uav_vision_set_start_stop_uav_rsp` | ⛔ |
| 0A:8D | 141 | `uav_vision_time_lapse_compass_cali_req_req` | `uav_vision_time_lapse_compass_cali_req_rsp` |  |
| 0A:94 | 148 | `uav_vision_set_SetTrackingTarget_req` | `uav_vision_set_SetTrackingTarget_rsp` | ⛔ |
| 0A:97 | 151 | `uav_vision_set_StopMultiTracking_req` | `uav_general_set_device_date_rsp` | ⛔ |
| 0A:9A | 154 | `uav_vision_set_smart_eye_select_target_req` | `uav_vision_set_smart_eye_select_target_rsp` | ⛔ |
| 0A:9B | 155 | `uav_vision_ack` | `uav_vision_get_pano_image_buf_rsp` |  |
| 0A:9B | 155 | `uav_vision_get_smart_eye_mot_switch_state_req` | `uav_vision_get_smart_eye_mot_switch_state_rsp` | ⛔ |
| 0A:BA | 186 | `uav_vision_target_manager_cmd_req` | `uav_vision_target_manager_cmd_rsp` |  |
| 0A:C1 | 193 | `uav_vision_set_poi_init_target_req` | `uav_vision_set_poi_init_target_rsp` | ⛔ |
| 0A:C4 | 196 | `uav_vision_set_poi_set_param_req` | `uav_vision_set_poi_set_param_rsp` | ⛔ |
| 0A:E7 | 231 | `uav_vision_tracking_box_to_nav_push` | `uav_vision_push_tracking_box_to_nav_rsp` | ★ |
| 0A:EC | 236 | `uav_vision_get_navi_homing_receive_msg_from_APP_req` | `uav_vision_get_navi_homing_receive_msg_from_APP_rsp` | ★ |
| 0A:F6 | 246 | `uav_vision_set_mastershot_set_param_req` | `uav_vision_set_mastershot_set_param_rsp` | ⛔ |
| 0A:F9 | 249 | `uav_vision_set_multi_target_mastershot_param_req_req` | `uav_vision_set_multi_target_mastershot_param_req_rsp` | ⛔ |

### cmd_set 0x0B: simulator

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 0B:01 | 1 | `uav_simulator_get_sim_scan_req` | `uav_simulator_get_sim_scan_rsp` |  |
| 0B:02 | 2 | `uav_simulator_get_sim_para_req` | `uav_simulator_get_sim_para_rsp` |  |
| 0B:04 | 4 | `uav_simulator_get_sim_command_req` | `uav_simulator_get_sim_command_rsp` |  |

### cmd_set 0x0D: smart battery

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 0D:01 | 1 | `uav_smart_battery_get_static_info_req` | `uav_smart_battery_get_static_info_rsp` | ★ |
| 0D:02 | 2 | `uav_smart_battery_get_dynamic_info_req` | `uav_smart_battery_get_dynamic_info_rsp` | ★ |
| 0D:03 | 3 | `uav_smart_battery_get_cell_voltage_req` | `uav_smart_battery_get_cell_voltage_rsp` | ★ |
| 0D:04 | 4 | `uav_smart_battery_get_get_barcode_req` | `uav_smart_battery_get_get_barcode_rsp` | ★ |
| 0D:11 | 17 | `uav_smart_battery_set_self_discharge_req` | `uav_smart_battery_set_self_discharge_rsp` | ★ ⛔ |
| 0D:24 | 36 | `uav_smart_battery_param_collect_req` | `uav_smart_battery_param_collect_rsp` | ★ |
| 0D:C4 | 196 | `uav_smart_battery_get_full_charge_condition_req` | `uav_smart_battery_get_full_charge_condition_rsp` | ★ |
| 0D:EF | 239 | `uav_smart_battery_clear_user_pd_blacklist_req` | `uav_smart_battery_clear_user_pd_blacklist_rsp` | ★ ⛔ |

### cmd_set 0x10: test

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 10:10 | 16 | `uav_test_fstest_enable_req` | `uav_test_fstest_enable_rsp` | ⛔ |
| 10:11 | 17 | `uav_test_fstest_run_case_req` | `uav_test_fstest_run_case_rsp` | ⛔ |
| 10:12 | 18 | `uav_test_fstest_get_case_status_req` | `uav_test_fstest_get_case_status_rsp` | ⛔ |
| 10:13 | 19 | `uav_test_get_fs_test_case_req` | `uav_test_fstest_case_case_cnt_rsp` | ⛔ |
| 10:14 | 20 | `uav_test_fstest_get_case_info_req` | `uav_test_fstest_get_case_info_rsp` | ⛔ |

### cmd_set 0x11: adsb / remote id

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 11:0C | 12 | `uav_adsb_get_adsb_on_off_req` | `uav_adsb_get_adsb_on_off_rsp` |  |
| 11:37 | 55 | `uav_adsb_set_set_adsb_agent_switch_req` | `uav_adsb_set_set_adsb_agent_switch_rsp` | ⛔ |
| 11:39 | 57 | `uav_adsb_set_adsb_test_data_req` | `uav_adsb_set_adsb_test_data_rsp` | ⛔ |
| 11:43 | 67 | `uav_adsb_set_app_update_pos_enc_req` | `uav_adsb_set_app_update_pos_enc_rsp` | ★ ⛔ |
| 11:4B | 75 | `uav_adsb_set_rid_registed_shared_key_query_req` | `uav_adsb_set_rid_registed_shared_key_query_rsp` | ⛔ |
| 11:50 | 80 | `uav_adsb_get_drone_dynamic_max_height_req` | `uav_adsb_get_drone_dynamic_max_height_rsp` |  |
| 11:D1 | 209 | `uav_adsb_get_realname_check_protocol_req` | `uav_adsb_get_realname_check_protocol_rsp` |  |
| 11:D5 | 213 | `uav_adsb_china_oid_publish_push` | `uav_adsb_push_china_oid_publish_rsp` | ★ |
| 11:D6 | 214 | `uav_adsb_set_china_uom_realname_tag_req` | `uav_adsb_set_china_uom_realname_tag_rsp` | ⛔ |

### cmd_set 0x12: bluetooth

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 12:07 | 7 | `uav_bt_get_get_ble_name_req` | `uav_bt_get_get_ble_name_rsp` |  |
| 12:08 | 8 | `uav_bt_set_set_ble_name_req` | `uav_bt_set_set_ble_name_rsp` | ⛔ |
| 12:0C | 12 | `uav_bt_get_bt_mac_addr_req` | `uav_bt_get_bt_mac_addr_rsp` |  |
| 12:21 | 33 | `bt_get_ibeacon_uuid_req` | `bt_get_ibeacon_uuid_rsp` |  |
| 12:22 | 34 | `uav_bt_get_hw_product_id_req` | `uav_bt_get_hw_product_id_rsp` | ★ |
| 12:8E | 142 | `uav_bt_network_report_action_req` | `uav_bt_network_report_action_rsp` | ⛔ |

### cmd_set 0x15: goggles

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 15:35 | 53 | `uav_goggles_app_to_glass_push_data_push` | `uav_goggles_push_app_to_glass_push_data_rsp` | ★ |

### cmd_set 0x18: cellular

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 18:15 | 21 | `uav_cellular4g_lte_apn_request_info` | `uav_cellular4g_lte_apn_response_info` |  |
| 18:43 | 67 | `uav_cellular4g_get_lte_dongle_fw_release_note_req` | `uav_cellular4g_get_lte_dongle_fw_release_note_rsp` |  |
| 18:45 | 69 | `uav_cellular4g_get_dongle_subscribe_info_req` | `uav_cellular4g_get_dongle_subscribe_info_rsp` | ★ |
| 18:4B | 75 | `uav_cellular4g_lte_esim_set_info` | `uav_cellular4g_lte_esim_response_info` | ⛔ |

### cmd_set 0x19: extend / control right

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 19:31 | 49 | `uav_extend_log_export_control_req` | `uav_extend_log_export_control_rsp` | ⛔ |
| 19:40 | 64 | `uav_extend_lock_right_of_control_req` | `uav_extend_lock_right_of_control_rsp` | ⛔ |
| 19:41 | 65 | `uav_extend_preempt_right_of_control_req` | `uav_extend_preempt_right_of_control_rsp` | ⛔ |
| 19:42 | 66 | `uav_extend_owner_ack` | `` |  |
| 19:45 | 69 | `uav_extend_set_notify_uncontrol_action_req` | `uav_extend_set_notify_uncontrol_action_rsp` | ⛔ |
| 19:46 | 70 | `uav_extend_set_task_occupy_control_req` | `uav_extend_set_task_occupy_control_rsp` | ⛔ |

### cmd_set 0x21: healthy (HMS)

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 21:04 | 4 | `uav_heathy_set_inject_test_req` | `uav_heathy_set_inject_test_rsp` | ⛔ |
| 21:05 | 5 | `uav_heathy_set_set_subscriber_req` | `uav_heathy_set_set_subscriber_rsp` | ★ ⛔ |
| 21:0A | 10 | `uav_heathy_get_history_cmd` | `uav_heathy_get_history_cmd_rsp` |  |

### cmd_set 0x22: fc2

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 22:1D | 29 | `uav_fc2_get_get_waypoint_info_req` | `uav_fc2_get_get_waypoint_info_rsp` | ⛔ |
| 22:27 | 39 | `uav_fc2_get_API_WP2_GET_BREAK_POINT_INFO_req` | `uav_fc2_get_API_WP2_GET_BREAK_POINT_INFO_rsp` |  |
| 22:28 | 40 | `uav_fc2_FC_FACTORY_CMD_req` | `uav_fc2_FC_FACTORY_CMD_rsp` |  |
| 22:48 | 72 | `uav_fc2_get_afqt_on_off_cmd_req` | `uav_fc2_get_afqt_on_off_cmd_rsp` |  |
| 22:60 | 96 | `uav_fc2_get_display_mode_on_off_req` | `uav_fc2_g` | ⛔ |
| 22:67 | 103 | `uav_fc2_get_GET_ESC_DATA_API_req` | `uav_fc2_get_GET_ESC_DATA_API_rsp` | ⛔ |
| 22:80 | 128 | `uav_fc_fs_cnt_down_to_app_push` | `uav_fc_push_fs_cnt_down_to_app_rsp` | ★ ⛔ |
| 22:AB | 171 | `uav_fc2_start_stop_wpmz_mission_req` | `uav_fc2_start_stop_wpmz_mission_rsp` | ⛔ |
| 22:AC | 172 | `uav_fc2_break_resume_wpmz_mission_req` | `uav_fc2_break_resume_wpmz_mission_rsp` | ⛔ |
| 22:AE | 174 | `uav_fc2_get_wp3_query_result_req` | `uav_fc2_get_wp3_query_result_rsp` |  |
| 22:AF | 175 | `uav_fc2_get_wp3_query_breakpoint_info_req` | `uav_fc2_get_wp3_query_breakpoint_info_rsp` |  |
| 22:CB | 203 | `uav_fc2_RC_DYN_HOMEPOINT_INFO_push` | `uav_fc2_push_RC_DYN_HOMEPOINT_INFO_rsp` | ★ ⛔ |

### cmd_set 0x23: navigation

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 23:04 | 4 | `uav_navigation_api_msg_result_ind_t_push` | `uav_navigation_push_api_msg_result_ind_t_rsp` | ★ |
| 23:12 | 18 | `uav_navigation_get_precise_photo_file_action_req` | `uav_navigation_get_precise_photo_file_action_rsp` | ⛔ |
| 23:13 | 19 | `uav_navigation_handheld_func_req` | `uav_navigation_handheld_func_rsp` |  |
| 23:15 | 21 | `uav_navigation_handheld_func_exit_req` | `uav_navigation_handheld_func_exit_rsp` |  |
| 23:16 | 22 | `uav_navigation_set_handheld_func_param_req` | `uav_navigation_set_handheld_func_param_rsp` | ⛔ |
| 23:18 | 24 | `navigation_smart_portrait_ctrl_action_req` | `navigation_smart_portrait_ctrl_action_rsp` | ⛔ |
| 23:19 | 25 | `navigation_get_smart_portrait_template_get_req` | `navigation_get_smart_portrait_template_get_rsp` |  |
| 23:A0 | 160 | `uav_navigation_set_keep_sticks_switch_req` | `uav_navigation_set_keep_sticks_switch_rsp` | ★ ⛔ |
| 23:B6 | 182 | `uav_navigation_fancy_mode_intend_from_app_req` | `uav_navigation_push_fancy_mode_intend_from_app_rsp` | ★ ⛔ |
| 23:C0 | 192 | `uav_navigation_offline_map_service_req` | `uav_navigation_offline_map_service_rsp` |  |

### cmd_set 0x24: perception

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 24:28 | 40 | `uav_perception_get_vps_cali_token_req` | `uav_perception_get_vps_cali_token_rsp` |  |

### cmd_set 0x49: sdk

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 49:80 | 128 | `uav_sdk_get_or_release_control_auth_t` | `uav_sdk_get_or_release_control_auth_ack_t` | ⛔ |

### cmd_set 0x50: esdd

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 50:05 | 5 | `uav_esdd_get_get_remote_audio_remux_state_req` | `uav_esdd_get_get_remote_audio_remux_state_rsp` |  |
| 50:08 | 8 | `uav_esdd_get_rgb_led_control_req` | `uav_esdd_get_rgb_led_control_rsp` | ⛔ |

### cmd_set 0x51: wlm (wireless link manager)

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 51:02 | 2 | `uav_wlm_get_link_mode_switch_req` | `uav_wlm_get_link_mode_switch_rsp` | ★ ⛔ |
| 51:09 | 9 | `uav_wlm_wlm_test_info_req` | `uav_wlm_wlm_test_info_rsp` | ★ ⛔ |
| 51:0D | 13 | `uav_wlm_get_wlm_debug_control_req` | `uav_wlm_get_wlm_debug_control_rsp` | ★ ⛔ |
| 51:15 | 21 | `uav_wlm_get_dev_select_req` | `uav_wlm_get_dev_select_rsp` | ★ |
| 51:1A | 26 | `uav_wlm_service_mode_switch_req` | `uav_wlm_service_mode_switch_rsp` | ★ ⛔ |
| 51:1E | 30 | `uav_wlm_DUSS_MB_CMD_WL_MANAGE_RM_CTRL_REPORT_push` | `uav_wlm_push_DUSS_MB_CMD_WL_MANAGE_RM_CTRL_REPORT_rsp` | ★ ⛔ |
| 51:2B | 43 | `uav_wlm_wlm_app_conn_product_info_push` | `uav_wlm_push_wlm_app_conn_product_info_rsp` | ★ |
| 51:42 | 66 | `uav_wlm_wlm_ability_nego_result_req` | `uav_wlm_wlm_ability_nego_result_rsp` | ★ |

### cmd_set 0x52: autoflight

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 52:01 | 1 | `uav_af_rc_start_autoflight_req` | `uav_af_set_rc_start_autoflight_rsp` | ⛔ |

### cmd_set 0x59: diag

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| 59:01 | 1 | `uav_diag_sys_diag_mode_switch_req` | `uav_diag_sys_diag_mode_switch_rsp` | ⛔ |
| 59:02 | 2 | `uav_diag_get_sys_diag_capability_req` | `uav_diag_get_sys_diag_capability_rsp` |  |
| 59:03 | 3 | `uav_diag_get_sys_diag_keep_alive_req` | `uav_diag_get_sys_diag_keep_alive_rsp` | ★ |
| 59:04 | 4 | `uav_diag_sys_diag_execute_req` | `uav_diag_sys_diag_execute_rsp` |  |
| 59:05 | 5 | `uav_diag_sys_diag_terminate_req` | `uav_diag_sys_diag_terminate_rsp` |  |
| 59:07 | 7 | `uav_diag_get_diag_result_cmd` | `uav_diag_get_diag_result_cmd_rsp` |  |

### cmd_set 0xEE: app

| set:id | dec id | req struct | rsp struct | flag |
|---|---|---|---|---|
| EE:02 | 2 | `uav_app_phone_camera_info_push` | `uav_app_push_phone_camera_info_rsp` | ★ |
| EE:07 | 7 | `uav_app_app_running_state_push` | `uav_app_push_app_running_state_rsp` | ★ |
| EE:08 | 8 | `uav_app_get_app_running_state_rsp` | `uav_app_get_app_running_state_req` | ★ |
| EE:12 | 18 | `uav_app_push_app_state_sync_req` | `uav_app_push_app_state_sync_rsp` | ★ |
| EE:2C | 44 | `uav_app_set_language_settings_req` | `uav_app_set_language_settings_rsp` | ★ ⛔ |

## Push packs observed passively by DJI Fly (set:id not statically resolvable)

DJI Fly registers observers (`BaseAbstraction::ObserverPushPack<T>`, `PackObserverHelper<T>`) for the classes below. **None of them has a matching subscribe command.** The app just listens, which means these pushes are broadcast by the devices to the app address. Where o-gs/dji-firmware-tools documents a legacy id, it is given as *legacy guess*.

| pack class | wire struct | legacy guess |
|---|---|---|

## Push packs that DJI Fly observes passively (set:id not statically resolvable)

DJI Fly registers observers for these classes (`BaseAbstraction::ObserverPushPack<T>`, `PackObserverHelper<T>`). **None of them has a matching subscribe command.** The app just listens, so the devices broadcast these pushes to the app address. Legacy ids from o-gs/dji-firmware-tools are given as guesses where they exist.

| pack class | wire struct | legacy id guess |
|---|---|---|
| `fc_osd_push` | `uav_fc_osd_push` | 03:43 |
| `fc_osd_low_freq_push` | `uav_fc_fc_osd_lowfreq_push` |  |
| `fc_battery_push` | `uav_fc_electricity_push` |  |
| `fc_battery_osd_push` | `uav_fc_battery_info_to_app_OSD_push` |  |
| `fc_gps_snr_push` | `uav_fc_gps_snr_push_push` |  |
| `general_osd_push` | `` |  |
| `radio_signal_push` | `uav_ofdm_radio_signal_push` |  |
| `linkquality_push` | `` | 09:08 (vt signal quality) |
| `sdr_current_cms_push` | `uav_ofdm_sdr_current_mcs_push` |  |
| `sdr_freq_power_push` | `` |  |
| `wlm_dev_osd_push` | `` |  |
| `wifi_low_freq_push` | `uav_wifi_signal_quality_push (?)` |  |
| `rc_battery_info_push` | `uav_rc_battery_info_push` |  |
| `rc_gps_info_push` | `uav_rc_gps_info_push` |  |
| `rc_channel_param_push` | `uav_rc_channel_params_push` | 06:05 |
| `rc_glass_state_to_app_push` | `uav_rc_GLASS_STATE_TO_APP_push` |  |
| `gimbal_attitude_push` | `` | 04:05 |
| `camera_status_info_push` | `uav_camera_push_camera_status_info_push` | 02:80 |
| `get_battery_dynamic_info_push` | `` | 0D:02 |
| `avoid_push` | `uav_fc_avoid_status_push` |  |

Every `uav_*_push` wire struct in the string table:

```
uav_adsb_RID_WORKING_STATUS_push uav_adsb_flightrestrict_config_push uav_camera_bargraph_info_push uav_camera_capture_para_push uav_camera_fov_para_push uav_camera_len_para_push uav_camera_playback_para_push uav_camera_push_camera_current_record_file_push uav_camera_push_camera_status_info_push uav_camera_storage_info_push uav_double_vision_uav59_self_test_push uav_esdd_audio_stream_send_push uav_esdd_shutdown_countdown_notice_push uav_extend_status_info_push uav_fc_avoid_status_push uav_fc_battery_info_to_app_OSD_push uav_fc_electricity_push uav_fc_fc_osd_lowfreq_push uav_fc_flylimit_version_push uav_fc_func_mcu_battery_capacity_gohome_landing_to_app_push uav_fc_gps_snr_push_l5_push uav_fc_gps_snr_push_push uav_fc_no_fly_area_push uav_fc_osd_push uav_general_accesslocker_v1_encryption_result_push uav_general_ce_info_show_push uav_gimbal_gimbal_type_push uav_gimbal_self_test_push uav_navigation_ar_sei_info_push uav_navigation_handheld_func_osd_push uav_navigation_push_exit_homing_message_to_app_push uav_navigation_push_keep_sticks_status_push uav_ofdm_RELAY_FUNC_STATUS_PUSH_push uav_ofdm_osd_push uav_ofdm_radio_signal_push uav_ofdm_sdr_current_mcs_push uav_ofdm_sdr_role_mode_push_push uav_perception_PUSH_DOWNWARD_EXCEPTION_DETECTION_STATUS_push uav_perception_PUSH_OA_STATUS_push uav_rc_GLASS_STATE_TO_APP_push uav_rc_battery_info_push uav_rc_channel_params_push uav_rc_gps_info_push uav_rc_ground_ofdm_self_test_push uav_rc_ground_wifi_self_test_push uav_rc_rc_osd_push uav_simulator_sim_cmd_status_push uav_vision_NAV_V1_HOMING_STATE_TO_APP_push uav_vision_NAV_V1_Homing_NFZ_State_to_APP_push uav_vision_SOT_BOX_FUSION_STATE_SEND_push uav_vision_camera_calibration_osd_push uav_vision_free_pano_cap_area_gnd_pos_info_push uav_vision_general_video_metadata_push uav_vision_mastershot_mult_obj_box_push_push uav_vision_ms_push_running_info_push uav_vision_navigation_osd_push uav_vision_pano_push uav_vision_pano_shot_position_and_process_to_navigation_push uav_vision_poi_response_target_push uav_vision_poi_status_push uav_vision_push_fixed_speed_status_push uav_vision_push_ms_video_info_push uav_vision_push_tracking_control_push uav_vision_sensor_state_push uav_vision_smart_eye_state_push_push uav_vision_target_manager_status_push uav_vision_time_lapse_compass_cali_status_push_push uav_vision_time_lapse_status_sync_push uav_vision_tips_info_push uav_vision_tracking_status_push uav_wifi_signal_quality_push uav_wifi_sw_dev_info_1_push uav_wlm_neigh_devices_push
```
