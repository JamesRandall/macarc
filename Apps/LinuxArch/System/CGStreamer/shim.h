// GStreamer for LinuxArch's video recorder, with helpers for what Swift
// can't call directly (macros and variadic functions).

#include <gst/gst.h>
#include <gst/app/gstappsrc.h>

static inline gboolean la_gst_has_element(const char *name) {
    GstElementFactory *factory = gst_element_factory_find(name);
    if (!factory) return FALSE;
    gst_object_unref(factory);
    return TRUE;
}

static inline GstAppSrc *la_gst_app_src(GstElement *pipeline, const char *name) {
    GstElement *element = gst_bin_get_by_name(GST_BIN(pipeline), name);
    return element ? GST_APP_SRC(element) : NULL;
}

static inline void la_gst_set_location(GstElement *pipeline, const char *sink, const char *location) {
    GstElement *element = gst_bin_get_by_name(GST_BIN(pipeline), sink);
    if (!element) return;
    g_object_set(element, "location", location, NULL);
    gst_object_unref(element);
}

/// A buffer holding a copy of `size` bytes, with its timing.
static inline GstBuffer *la_gst_buffer(const void *data, gsize size, GstClockTime pts, GstClockTime duration) {
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, size, NULL);
    if (!buffer) return NULL;
    gst_buffer_fill(buffer, 0, data, size);
    GST_BUFFER_PTS(buffer) = pts;
    GST_BUFFER_DURATION(buffer) = duration;
    return buffer;
}

/// The pipeline's first error, as a newly allocated string (g_free it), or
/// NULL. With `wait`, waits for the end of the stream or an error.
static inline gchar *la_gst_error(GstElement *pipeline, gboolean wait) {
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = wait
        ? gst_bus_timed_pop_filtered(bus, GST_CLOCK_TIME_NONE, GST_MESSAGE_EOS | GST_MESSAGE_ERROR)
        : gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
    gst_object_unref(bus);
    if (!message) return NULL;
    gchar *text = NULL;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        GError *error = NULL;
        gst_message_parse_error(message, &error, NULL);
        text = g_strdup(error ? error->message : "unknown GStreamer error");
        if (error) g_error_free(error);
    }
    gst_message_unref(message);
    return text;
}
