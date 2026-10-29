// GTK4 and libadwaita for LinuxArch, with helpers for what Swift can't call
// directly: macros, casts and variadic functions.

#include <adwaita.h>
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <sys/eventfd.h>

// libdispatch's main queue, which LinuxArch runs from GLib's main loop (as
// Foundation's run loop does), so DispatchQueue.main and the main actor work.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

static inline gboolean la_drain_eventfd(int fd) {
    eventfd_t value;
    return eventfd_read(fd, &value) == 0;
}

static inline gulong la_signal_connect(gpointer instance, const char *signal, GCallback handler, gpointer data,
                                       GClosureNotify destroy, gboolean after) {
    return g_signal_connect_data(instance, signal, handler, data, destroy, after ? G_CONNECT_AFTER : 0);
}

static inline void la_set_bool(gpointer object, const char *name, gboolean value) {
    g_object_set(object, name, value, NULL);
}

static inline void la_set_int(gpointer object, const char *name, gint value) {
    g_object_set(object, name, value, NULL);
}

static inline void la_set_double(gpointer object, const char *name, gdouble value) {
    g_object_set(object, name, value, NULL);
}

static inline void la_set_string(gpointer object, const char *name, const char *value) {
    g_object_set(object, name, value, NULL);
}

static inline void la_set_object(gpointer object, const char *name, gpointer value) {
    g_object_set(object, name, value, NULL);
}

static inline const GVariantType *la_variant_type_string(void) { return G_VARIANT_TYPE_STRING; }
static inline const GVariantType *la_variant_type_boolean(void) { return G_VARIANT_TYPE_BOOLEAN; }
static inline const GVariantType *la_variant_type_int32(void) { return G_VARIANT_TYPE_INT32; }

static inline GType la_type_file_list(void) { return GDK_TYPE_FILE_LIST; }
static inline GType la_type_file(void) { return G_TYPE_FILE; }
static inline GType la_type_string(void) { return G_TYPE_STRING; }

/// The first file's path in a dropped value (a file or a file list), newly
/// allocated (g_free it), or NULL.
static inline char *la_dropped_path(const GValue *value) {
    if (G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GSList *files = g_value_get_boxed(value);
        return files ? g_file_get_path(files->data) : NULL;
    }
    if (G_VALUE_HOLDS(value, G_TYPE_FILE)) {
        return g_file_get_path(g_value_get_object(value));
    }
    return NULL;
}

/// A string list model's item's text.
static inline const char *la_string_object_text(gpointer item) {
    return gtk_string_object_get_string(GTK_STRING_OBJECT(item));
}

/// Paints `widget` (and what's inside it) to a PNG file, as it's shown.
static inline gboolean la_save_widget_png(GtkWidget *widget, const char *path) {
    GtkNative *native = gtk_widget_get_native(widget);
    if (!native) return FALSE;
    GskRenderer *renderer = gtk_native_get_renderer(native);
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    if (!renderer || width <= 0 || height <= 0) return FALSE;
    GdkPaintable *paintable = gtk_widget_paintable_new(widget);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gdk_paintable_snapshot(paintable, snapshot, width, height);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    gboolean saved = FALSE;
    if (node) {
        graphene_rect_t viewport = GRAPHENE_RECT_INIT(0, 0, width, height);
        GdkTexture *texture = gsk_renderer_render_texture(renderer, node, &viewport);
        saved = gdk_texture_save_to_png(texture, path);
        g_object_unref(texture);
        gsk_render_node_unref(node);
    }
    g_object_unref(paintable);
    return saved;
}

// GDK's Wayland objects, for the pointer lock (NULL when not on Wayland).
#include <gdk/wayland/gdkwayland.h>

static inline void *la_wayland_display(GtkWidget *widget) {
    GdkDisplay *display = gtk_widget_get_display(widget);
    return GDK_IS_WAYLAND_DISPLAY(display) ? gdk_wayland_display_get_wl_display(display) : NULL;
}

static inline void *la_wayland_surface(GtkWidget *widget) {
    GtkNative *native = gtk_widget_get_native(widget);
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    return surface && GDK_IS_WAYLAND_SURFACE(surface) ? gdk_wayland_surface_get_wl_surface(surface) : NULL;
}

static inline void *la_wayland_pointer(GtkWidget *widget) {
    GdkDisplay *display = gtk_widget_get_display(widget);
    if (!GDK_IS_WAYLAND_DISPLAY(display)) return NULL;
    GdkSeat *seat = gdk_display_get_default_seat(display);
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    return pointer ? gdk_wayland_device_get_wl_pointer(pointer) : NULL;
}

/// Hides `widget` while `breakpoint` applies.
static inline void la_breakpoint_hide(AdwBreakpoint *breakpoint, GtkWidget *widget) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_BOOLEAN);
    g_value_set_boolean(&value, FALSE);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(widget), "visible", &value);
    g_value_unset(&value);
}

/// Sets a boolean property while a breakpoint applies.
static inline void la_breakpoint_set_bool(AdwBreakpoint *breakpoint, gpointer object, const char *property, gboolean on) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_BOOLEAN);
    g_value_set_boolean(&value, on);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &value);
    g_value_unset(&value);
}

/// Every file's path in a dropped value (a file list, or one file), as a
/// NULL-terminated array to free with g_strfreev, or NULL.
static inline char **la_dropped_paths(const GValue *value) {
    GPtrArray *paths = g_ptr_array_new();
    if (G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        for (GSList *file = g_value_get_boxed(value); file; file = file->next) {
            char *path = g_file_get_path(file->data);
            if (path) g_ptr_array_add(paths, path);
        }
    } else if (G_VALUE_HOLDS(value, G_TYPE_FILE)) {
        char *path = g_file_get_path(g_value_get_object(value));
        if (path) g_ptr_array_add(paths, path);
    }
    g_ptr_array_add(paths, NULL);
    return (char **)g_ptr_array_free(paths, FALSE);
}

/// The paths of the files in a list model of GFiles (a file dialog's
/// choices), as `la_dropped_paths`.
static inline char **la_file_list_paths(GListModel *files) {
    GPtrArray *paths = g_ptr_array_new();
    guint count = files ? g_list_model_get_n_items(files) : 0;
    for (guint i = 0; i < count; i++) {
        GFile *file = g_list_model_get_item(files, i);
        char *path = g_file_get_path(file);
        if (path) g_ptr_array_add(paths, path);
        g_object_unref(file);
    }
    g_ptr_array_add(paths, NULL);
    return (char **)g_ptr_array_free(paths, FALSE);
}

/// Content to drag out: the files at `paths` (NULL-terminated), which a
/// file manager copies.
static inline GdkContentProvider *la_content_provider_for_paths(const char *const *paths) {
    GSList *files = NULL;
    for (int i = 0; paths[i]; i++) {
        files = g_slist_prepend(files, g_file_new_for_path(paths[i]));
    }
    files = g_slist_reverse(files);
    GdkFileList *list = gdk_file_list_new_from_list(files);
    g_slist_free_full(files, g_object_unref);
    GdkContentProvider *provider = gdk_content_provider_new_typed(GDK_TYPE_FILE_LIST, list);
    g_boxed_free(GDK_TYPE_FILE_LIST, list);
    return provider;
}
