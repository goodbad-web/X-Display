# OBSERVABILITY: 計測・ログ設計

## 必須ログ
- app_start
- permission_check_result
- virtual_display_created
- virtual_display_destroyed
- scstream_started
- scstream_frame_received
- scstream_stalled
- scstream_restarted
- encoder_started
- encoder_output_frame
- socket_connected
- socket_disconnected
- decoder_started
- metal_frame_rendered
- reconnect_started
- reconnect_succeeded
- reconnect_failed
- client_window_opened
- client_window_closed

## フレームごとのtimestamp
- capture_ts
- encode_in_ts
- encode_out_ts
- socket_send_ts
- socket_recv_ts
- decode_out_ts
- render_ts

## 派生メトリクス
- capture_to_encode_ms
- encode_ms
- network_ms
- decode_ms
- render_ms
- end_to_end_ms
- dropped_frame_count
- reconnect_count
- scstream_restart_count

## Log Levels
- TRACE
- DEBUG
- INFO
- WARN
- ERROR
- FATAL

## Log Sinks
- stdout
- os_log
- rotating file
- user export zip