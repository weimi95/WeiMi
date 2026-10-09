#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <string.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "微密文件");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "微密文件");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // 剪贴板文件通道：提供 x-special/gnome-copied-files 与 text/uri-list 两种 target，
  // GNOME Files / KDE Dolphin / 大部分文件管理器可直接粘贴
  static gchar* clip_payload = nullptr;  // "copy\nfile:///p1\nfile:///p2"

  fl_method_channel_set_method_call_handler(
      fl_method_channel_new(
          fl_engine_get_binary_messenger(fl_view_get_engine(view)),
          "com.weimi95.weimi/clipboard_files",
          FL_METHOD_CODEC(fl_standard_method_codec_get_instance())),
      [](FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
        (void)channel;
        (void)user_data;
        if (strcmp(fl_method_call_get_name(call), "copyFiles") != 0) {
          g_autoptr(FlMethodResponse) ni =
              fl_method_not_implemented_response_new();
          fl_method_call_respond(call, ni, nullptr);
          return;
        }
        FlValue* args = fl_method_call_get_args(call);
        FlValue* paths_val = fl_value_lookup_string(args, "paths");
        if (paths_val == nullptr ||
            fl_value_get_type(paths_val) != FL_VALUE_TYPE_LIST) {
          g_autoptr(FlMethodResponse) err =
              fl_method_error_response_new("bad_args", "missing paths", nullptr);
          fl_method_call_respond(call, err, nullptr);
          return;
        }
        GString* buf = g_string_new("copy");
        size_t n = fl_value_get_length(paths_val);
        for (size_t i = 0; i < n; i++) {
          FlValue* v = fl_value_get_list_value(paths_val, i);
          if (fl_value_get_type(v) != FL_VALUE_TYPE_STRING) continue;
          gchar* uri = g_filename_to_uri(fl_value_get_string(v), nullptr, nullptr);
          if (uri == nullptr) continue;
          g_string_append_c(buf, '\n');
          g_string_append(buf, uri);
          g_free(uri);
        }
        if (clip_payload != nullptr) g_free(clip_payload);
        clip_payload = g_string_free(buf, FALSE);

        static const GtkTargetEntry targets[] = {
            {(gchar*)"x-special/gnome-copied-files", 0, 0},
            {(gchar*)"text/uri-list", 0, 1},
        };
        GtkClipboard* clipboard =
            gtk_clipboard_get_default(gdk_display_get_default());
        gtk_clipboard_set_with_data(
            clipboard, targets, G_N_ELEMENTS(targets),
            [](GtkClipboard*, GtkSelectionData* selection_data, guint,
               gpointer) {
              const gchar* target_name = gdk_atom_name(
                  gtk_selection_data_get_target(selection_data));
              if (target_name == nullptr || clip_payload == nullptr) return;
              GString* out = g_string_new("");
              if (strcmp(target_name, "text/uri-list") == 0) {
                // uri-list：去掉 "copy" 行，换行改 \r\n
                gchar** lines = g_strsplit(clip_payload, "\n", -1);
                for (int i = 0; lines[i] != nullptr; i++) {
                  if (strcmp(lines[i], "copy") == 0) continue;
                  g_string_append(out, lines[i]);
                  g_string_append(out, "\r\n");
                }
                g_strfreev(lines);
              } else {
                g_string_append(out, clip_payload);
              }
              gtk_selection_data_set(
                  selection_data,
                  gdk_atom_intern(target_name, FALSE), 8,
                  reinterpret_cast<const guchar*>(out->str),
                  static_cast<gint>(out->len));
              g_string_free(out, TRUE);
            },
            [](GtkClipboard*, gpointer) {}, nullptr);
        gtk_clipboard_store(clipboard);

        g_autoptr(FlMethodResponse) resp =
            fl_method_success_response_new(fl_value_new_bool(TRUE));
        fl_method_call_respond(call, resp, nullptr);
      },
      nullptr, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}