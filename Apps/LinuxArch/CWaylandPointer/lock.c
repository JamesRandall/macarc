// Pointer lock on Wayland, on an event queue of its own (so GDK's events are
// left alone): the compositor holds the pointer still over the surface and
// sends its movements.

#include "WaylandPointer.h"

#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "pointer-constraints-unstable-v1-client-protocol.h"
#include "relative-pointer-unstable-v1-client-protocol.h"

struct la_pointer_lock {
    struct wl_display *display;
    struct wl_event_queue *queue;
    struct wl_registry *registry;
    struct zwp_pointer_constraints_v1 *constraints;
    struct zwp_relative_pointer_manager_v1 *relative_manager;
    struct zwp_locked_pointer_v1 *locked;
    struct zwp_relative_pointer_v1 *relative;
    bool is_locked;
    la_relative_motion motion;
    void *data;
};

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    la_pointer_lock *lock = data;
    if (strcmp(interface, zwp_pointer_constraints_v1_interface.name) == 0) {
        lock->constraints = wl_registry_bind(registry, name, &zwp_pointer_constraints_v1_interface, 1);
    } else if (strcmp(interface, zwp_relative_pointer_manager_v1_interface.name) == 0) {
        lock->relative_manager = wl_registry_bind(registry, name, &zwp_relative_pointer_manager_v1_interface, 1);
    }
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {}

static const struct wl_registry_listener registry_listener = { global, global_remove };

static void locked(void *data, struct zwp_locked_pointer_v1 *pointer) {
    ((la_pointer_lock *)data)->is_locked = true;
}

static void unlocked(void *data, struct zwp_locked_pointer_v1 *pointer) {
    ((la_pointer_lock *)data)->is_locked = false;
}

static const struct zwp_locked_pointer_v1_listener locked_listener = { locked, unlocked };

static void relative_motion(void *data, struct zwp_relative_pointer_v1 *pointer, uint32_t time_hi, uint32_t time_lo,
                            wl_fixed_t dx, wl_fixed_t dy, wl_fixed_t dx_unaccelerated, wl_fixed_t dy_unaccelerated) {
    la_pointer_lock *lock = data;
    if (lock->is_locked && lock->motion) {
        lock->motion(lock->data, wl_fixed_to_double(dx), wl_fixed_to_double(dy));
    }
}

static const struct zwp_relative_pointer_v1_listener relative_listener = { relative_motion };

la_pointer_lock *la_pointer_lock_new(void *display, void *surface, void *pointer, la_relative_motion motion, void *data) {
    if (!display || !surface || !pointer) return NULL;
    la_pointer_lock *lock = calloc(1, sizeof(la_pointer_lock));
    lock->display = display;
    lock->motion = motion;
    lock->data = data;
    lock->queue = wl_display_create_queue(lock->display);
    struct wl_display *wrapper = wl_proxy_create_wrapper(lock->display);
    wl_proxy_set_queue((struct wl_proxy *)wrapper, lock->queue);
    lock->registry = wl_display_get_registry(wrapper);
    wl_proxy_wrapper_destroy(wrapper);
    wl_registry_add_listener(lock->registry, &registry_listener, lock);
    wl_display_roundtrip_queue(lock->display, lock->queue);
    if (!lock->constraints || !lock->relative_manager) {
        la_pointer_lock_free(lock);
        return NULL;
    }
    lock->locked = zwp_pointer_constraints_v1_lock_pointer(lock->constraints, surface, pointer, NULL,
                                                           ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
    zwp_locked_pointer_v1_add_listener(lock->locked, &locked_listener, lock);
    lock->relative = zwp_relative_pointer_manager_v1_get_relative_pointer(lock->relative_manager, pointer);
    zwp_relative_pointer_v1_add_listener(lock->relative, &relative_listener, lock);
    wl_display_flush(lock->display);
    return lock;
}

void la_pointer_lock_dispatch(la_pointer_lock *lock) {
    if (!lock) return;
    wl_display_flush(lock->display);
    wl_display_dispatch_queue_pending(lock->display, lock->queue);
}

bool la_pointer_lock_is_locked(la_pointer_lock *lock) {
    return lock && lock->is_locked;
}

void la_pointer_lock_free(la_pointer_lock *lock) {
    if (!lock) return;
    if (lock->relative) zwp_relative_pointer_v1_destroy(lock->relative);
    if (lock->locked) zwp_locked_pointer_v1_destroy(lock->locked);
    if (lock->relative_manager) zwp_relative_pointer_manager_v1_destroy(lock->relative_manager);
    if (lock->constraints) zwp_pointer_constraints_v1_destroy(lock->constraints);
    if (lock->registry) wl_registry_destroy(lock->registry);
    wl_display_flush(lock->display);
    if (lock->queue) wl_event_queue_destroy(lock->queue);
    free(lock);
}
