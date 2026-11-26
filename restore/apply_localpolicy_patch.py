import sys
path = sys.argv[1]
src = open(path).read()

proto_anchor = '#include "recovery.h"\n'
proto_add = '\n/* retasuVM patch (in patched recovery.c) */\nint recovery_send_localpolicy(struct idevicerestore_client_t* client, plist_t build_identity);\n'
assert proto_anchor in src and 'recovery_send_localpolicy' not in src
src = src.replace(proto_anchor, proto_anchor + proto_add, 1)

call_anchor = '\t\tmutex_lock(&client->device_event_mutex);\n\n\t\t/* now we load the iBEC */\n'
call_add = ('\t\tmutex_lock(&client->device_event_mutex);\n\n'
            '\t\t/* retasuVM patch: dfu_enter_recovery sends Ap,LocalPolicy before\n'
            '\t\t   iBEC on the DFU path; a client that starts in recovery mode must\n'
            '\t\t   do the same or iBEC won\'t start. Failure is not fatal here: when\n'
            '\t\t   the device is already running iBEC (staged clients), the policy\n'
            '\t\t   was installed by the earlier stage, so just warn and continue. */\n'
            '\t\tif (client->macos_variant) {\n'
            '\t\t\tif (recovery_send_localpolicy(client, build_identity) < 0) {\n'
            '\t\t\t\tlogger(LL_WARNING, "Unable to send Ap,LocalPolicy (continuing)\\n");\n'
            '\t\t\t}\n'
            '\t\t}\n\n'
            '\t\t/* now we load the iBEC */\n')
assert call_anchor in src
src = src.replace(call_anchor, call_add, 1)
open(path, 'w').write(src)
print('localpolicy patch applied')
