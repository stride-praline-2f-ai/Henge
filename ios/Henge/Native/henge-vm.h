/* The engine (HengeVM, ../host/vm.h) as the Swift side sees it. */
#ifndef HENGE_VM_H
#define HENGE_VM_H

#include <stddef.h>
#include <stdint.h>
#include "../../../host/disk_resize.h"

/* Builds the machine from imported files, on the JIT region the app holds
   (henge_ios_jit_prewarm), and starts it. 0, or -1 with a reason in err. */
int henge_vm_boot(const char *rom, const char *disk, const char *aux, uint64_t ecid, uint64_t seed, uint64_t ram_mb,
                  int cpus, char *err, size_t errlen);
/* Installs macOS from an IPSW onto a new machine (blank disk and auxiliary
   storage): boots the ROM in DFU mode and runs the restore over its USB port,
   as Virtualization.framework's installer does. workdir is scratch space.
   0, or -1 with a reason in err; progress below. */
int henge_vm_install(const char *rom, const char *disk, const char *aux, uint64_t ecid, const char *ipsw,
                     const char *workdir, uint64_t ram_mb, int cpus, char *err, size_t errlen);
/* The restore's step (0 detect, 1 prepare, 2 system image, 3 verify, 4 firmware,
   6 FUD, 7 personalized images; 100 done, 101 failed) and how far it is (0..1). */
int henge_install_step(void);
double henge_install_progress(void);
/* Writes a blank auxiliary storage file (what VZMacAuxiliaryStorage makes). 0 or -1. */
int henge_make_aux(const char *path);

/* Instant resume (../host/snapshot.h). henge_vm_suspend stops a running Mac where it is and writes it to path; it
   stays paused (state 4) until henge_vm_continue runs it on, or henge_vm_stop ends it. 0 if saved; -1 with a
   reason if not (the Mac then still runs, unless it stopped by itself meanwhile). henge_vm_resume is henge_vm_boot
   from a saved Mac: the same settings, and the disk exactly as it was saved, or it fails and nothing runs. ident is
   what the file is valid for (the app's build, the Mac, its disk). henge_vm_saved_ok: 0 if path is a whole saved
   Mac for ident, and its size and save time. */
int henge_vm_suspend(const char *path, const char *ident, char *err, size_t errlen);
/* The two halves of henge_vm_suspend. Pausing needs the GPU (what only it holds goes back into the Mac's memory), which
   iOS refuses an app in the background: pause when Henge stops being active, save once it is in the background. */
int henge_vm_pause(char *err, size_t errlen);
int henge_vm_pause_generation(uint64_t generation, char *err, size_t errlen);
int henge_vm_save(const char *path, const char *ident, char *err, size_t errlen);
typedef struct HengeSaveRequest HengeSaveRequest;
/* Owned per save, never reused. Cancel/progress do not acquire the VM lock.
   The owner must keep the request alive until run/cancel/progress calls finish. */
HengeSaveRequest *henge_vm_save_request(uint64_t generation, int background);
void henge_vm_save_cancel(HengeSaveRequest *request);
void henge_vm_save_free(HengeSaveRequest *request);
int henge_vm_save_run(HengeSaveRequest *request, const char *path, const char *ident, char *err, size_t errlen);
typedef struct HengeSaveProgress { uint64_t scanned, total; int phase, cancelled; } HengeSaveProgress;
/* phase: 0 pending, 1 saving, 2 committed, 3 cancelled, 4 failed. */
void henge_vm_save_progress(HengeSaveRequest *request, HengeSaveProgress *out);
typedef struct HengeSavedInfo { uint64_t bytes, ram_mb; int64_t saved_at; uint32_t cpus; } HengeSavedInfo;
int henge_vm_saved_info(const char *path, char *ident, size_t capacity, HengeSavedInfo *info);
int henge_vm_continue(void);
/* Invalidate the saved file under the same VM lock, before guest disks can
   change. A failed unlink leaves the Mac paused and reports an error. */
int henge_vm_continue_generation(uint64_t generation, const char *saved_path, char *err, size_t errlen);
int henge_vm_resume(const char *rom, const char *disk, const char *aux, uint64_t ecid, uint64_t seed, uint64_t ram_mb,
                    int cpus, const char *path, const char *ident, char *err, size_t errlen);
int henge_vm_saved_ok(const char *path, const char *ident, uint64_t *bytes, int64_t *saved_at);

/* 0 not started, 1 running, 2 stopped, 3 starting/stopping, 4 paused (saved, or being saved).
   Normal guests are fully released before state 2; installer sessions retain
   their restore stack and can_start stays false. */
/* Static observer, called after state changes, possibly under the bridge lock.
   Enqueue work only; do not reenter VM APIs. NULL unregisters future captures. */
void henge_vm_set_state_notify(void (*notify)(void));
int henge_vm_state(void);
/* A new generation starts with each successful boot, even in the same view. */
uint64_t henge_vm_generation(void);
int henge_vm_can_start(void);
int henge_disk_expansion_info(const char *path,HvDiskExpansionInfo *info,char *error,size_t error_bytes);
int henge_disk_prepare_apfs(const char *path,HvDiskExpansionInfo *info,char *error,size_t error_bytes);
int henge_disk_expand(const char *path,uint64_t bytes,unsigned *last_apfs,char *error,size_t error_bytes);
/* Human-readable terminal reason, once state is 2. */
const char *henge_vm_exit_reason(void);
/* Terminal outcome after state == 2. Generic HALT alone does not prove a
   guest shutdown (it also covers reset, host stop and guest panic). */
enum HengeVmOutcome {
    HENGE_VM_OUTCOME_ERROR, HENGE_VM_OUTCOME_SHUTDOWN, HENGE_VM_OUTCOME_RESTART,
    HENGE_VM_OUTCOME_HOST_STOP, HENGE_VM_OUTCOME_PANIC
};
int henge_vm_exit_outcome(void);
void henge_vm_stop(void);
int henge_vm_stop_generation(uint64_t generation);
/* Testing: sets a translation knob (core/machine.h) in the running machine; nonzero if it exists. */
int henge_vm_knob(const char *name, int value);
/* The memory balloon (only with HV_BALLOON set before boot): asks the guest to hand over target_mb (when >= 0)
   and returns how many MB it has handed over, or -1 without a balloon. */
long henge_vm_balloon(long target_mb);

/* Progress, for the session screen. */
/* One lifecycle-consistent observation. epoch changes on boot, pause, continue
   and stop, including transitions the UI missed while iOS suspended it.
   Paused/stopped cumulative counters remain readable until the next boot. */
typedef struct HengeVmCounters {
    uint64_t generation, epoch, blocks, gpu_frames, tx, rx;
    int state;
} HengeVmCounters;
void henge_vm_counters(HengeVmCounters *out);
typedef struct HengeVmObservation { HengeVmCounters counters; int cpus_on, guest_el0; } HengeVmObservation;
/* Main-thread observation: 0 when a lifecycle writer owns the VM, never wait
   for GPU quiescence, disk operations or restoration on the UI thread. */
int henge_vm_try_observation(HengeVmObservation *out);
typedef struct HengeVmResources {
    uint64_t process_cpu_us, footprint, resident, headroom, jit_used, jit_capacity, translations, full_flushes;
    uint64_t gamepad_delivered, gamepad_coalesced, gamepad_overflow;
    uint64_t mouse_delivered, mouse_dropped, mouse_queued;
    uint64_t replay_gpu_completed, replay_gpu_ns, replay_gpu_max_ns, replay_gpu_unavailable;
    uint64_t metal_allocated, metal4_gpu_completed, metal4_gpu_ns, metal4_gpu_max_ns;
    /* Raw HOST_VM_INFO64 categories. Some overlap; never sum as allocatable RAM. */
    uint64_t system_free, system_speculative, system_purgeable, system_compressed;
    uint64_t system_wired, system_active, system_inactive, system_external, system_internal;
    uint64_t disk[2][6];
    int disk_timing_enabled[2];
    int detailed_counters;
    unsigned available; /* bits: 0 CPU, 1 memory, 2 headroom, 3 VM, 4 classic replay timing, 5 Metal4 timing, 6 Metal allocation, 7 system VM */
    uint64_t generation, epoch;
    int state;
} HengeVmResources;
/* GPU timing only during explicit capture; does not enable per-access stats. */
void henge_vm_capture_timing(int enabled);
void henge_vm_resources(HengeVmResources *out); /* explicit capture only; no sampling thread */
/* Nonblocking status: backing 0 none, 1 kernel exclusion, 2 file, 3 anonymous.
   state -1 means a lifecycle transition owns the VM; bytes/backing are unset. */
typedef struct HengeGuestMemoryStatus { uint64_t bytes; int backing, state; } HengeGuestMemoryStatus;
void henge_vm_guest_memory(HengeGuestMemoryStatus *out);
int henge_vm_gamepad(int connected,uint16_t buttons,int16_t lx,int16_t ly,int16_t rx,int16_t ry,
                     uint8_t left,uint8_t right,uint8_t hat);
void henge_vm_input_key(unsigned source,uint8_t usage,int down);
void henge_vm_input_button(unsigned source,int button,int down);
void henge_vm_input_release(unsigned source); /* 1 Link, 2 mapped gamepad, 3 gamepad pad, 4 physical mouse, 5 touch pad, 6 buttons, 7 volume; keyboard 4 physical */
void henge_vm_trim_memory(void); /* release disposable caches; preserves guest RAM and live code */
void henge_vm_log_cache(void);           /* optional per-CPU cache-use diagnostics */
uint64_t henge_vm_blocks(void);            /* blocks the CPUs entered */
uint64_t henge_vm_net_frames(int sent);    /* Ethernet frames out (sent = 1) and in */
uint64_t henge_vm_dns(int which);          /* guest DNS queries answered through iOS's resolver (0), handed to libslirp (1), unanswered in time (2) */
int henge_vm_cpus_on(void);                /* CPUs the guest has started */
int henge_vm_guest_el0(void);              /* any CPU running user code right now */

/* Input: Linux key codes, relative pointer, buttons 0 left 1 right 2 middle. */
/* The shared folder and clipboard (host/share.c). henge_vm_share goes before henge_vm_boot; agent may be NULL.
   henge_share_take_clipboard returns what the guest copied, once: a malloc'd string, or NULL. */
void henge_vm_share(const char *folder, const char *socket_path, const char *agent);
void henge_share_set_clipboard(const char *text);
unsigned long henge_share_publish_clipboard(const char *text);
int henge_share_clipboard_ready(void);
int henge_share_clipboard_delivered(unsigned long seq);
char *henge_share_take_clipboard(void);
long henge_share_agent_seen(void);

/* The size macOS is told its screen is. Before henge_vm_boot. */
void henge_vm_set_display(uint32_t width, uint32_t height);
/* The panel's physical size; 0, 0 for the default (a ~122 ppi, 1x screen). Before boot. */
void henge_vm_set_display_mm(uint32_t width_mm, uint32_t height_mm);
int henge_vm_set_link_display(uint32_t width, uint32_t height, uint32_t width_mm, uint32_t height_mm, uint32_t hz);
typedef struct HengeVmDisplayMode { uint32_t width,height,width_mm,height_mm,hz; } HengeVmDisplayMode;
/* 0: mode copied, -1: absent, -2: lifecycle transition; never blocks UI. */
int henge_vm_display_mode(unsigned port,HengeVmDisplayMode *out);
void henge_vm_link_connected(int connected);
void henge_vm_mirror_refresh(void);
int henge_vm_audio_event(uint64_t generation,int recover);
void henge_vm_key(uint16_t code, int down);
void henge_vm_key_hid(uint8_t usage, int down); /* a hardware keyboard: iOS gives each key's HID usage */
void henge_vm_mouse_move(int dx, int dy);
void henge_vm_mouse_button(int button, int down);
/* Wheel units: dy > 0 up, dx > 0 right. */
void henge_vm_mouse_scroll(int dx, int dy);
/* The Magic Trackpad 2 the Mac sees on its USB bus: a finger on it. phase: 0 down, 1 move, 2 up;
   finger a stable 1..15 per touch; x, y sensor units 0..8134, 0..5206. ts_ms is the touch
   sample's own clock in ms, so the guest computes finger speed from real sample timing. */
void henge_vm_touch(int finger, int phase, int x, int y, uint32_t ts_ms);
void henge_vm_touch_frame(uint32_t ts_ms); /* commit one frame with every finger that moved */
void henge_vm_touch_button(int down); /* the pad's full press (a click) */
/* Where the guest has its pointer, in display pixels. 0, or -1 before it has one. */
int henge_vm_pointer(int *x, int *y);
/* A small picture of the display, BGRA, width * height * 4 bytes. 0, or -1 before anything shows. */
int henge_vm_snapshot(uint8_t *bgra, int width, int height);

/* The boot framebuffer (Apple logo and progress bar), 32-bit BGRA, or -1 if
   the kernel has not got that far. A successful call returns an owned copy;
   release it with henge_vm_free_display after use. */
/// Where the Mac's GPU frames go: a CAMetalLayer. Keep it alive while the machine runs.
void henge_vm_set_display_layer(void *layer);
/// How many frames have gone to it.
uint64_t henge_vm_gpu_frames(void);
int henge_vm_boot_display(const uint8_t **pixels, int *width, int *height, int *stride);
void henge_vm_free_display(const uint8_t *pixels);

/* The largest single mapping the address space takes right now, in MB (the
   increased virtual addressing entitlement raises it). */
uint64_t henge_largest_reservation_gb(void); /* measuring: the biggest PROT_NONE reservation, in GB */
uint64_t henge_largest_mapping_mb(void);
/* Bytes this process may still allocate before jetsam (os_proc_available_memory). */
size_t henge_available_memory(void);

#endif
