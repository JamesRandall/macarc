// Locking the pointer to a Wayland surface and reading its movements.

#pragma once

#include <stdbool.h>

typedef struct la_pointer_lock la_pointer_lock;
typedef void (*la_relative_motion)(void *data, double dx, double dy);

/// Locks the pointer to `surface` (a wl_surface, with `display` a
/// wl_display and `pointer` a wl_pointer, GDK's), calling `motion` with
/// each movement. NULL if the compositor can't.
la_pointer_lock *la_pointer_lock_new(void *display, void *surface, void *pointer, la_relative_motion motion, void *data);
/// Runs the lock's events (call often).
void la_pointer_lock_dispatch(la_pointer_lock *lock);
/// Whether the compositor has the pointer locked now.
bool la_pointer_lock_is_locked(la_pointer_lock *lock);
/// Unlocks.
void la_pointer_lock_free(la_pointer_lock *lock);
