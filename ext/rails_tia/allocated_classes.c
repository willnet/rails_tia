#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/st.h>

struct tracker {
    st_table *classes;
    VALUE last_class;
    int enabled;
};

static int mark_class(st_data_t key, st_data_t value, st_data_t arg)
{
    /* Identity keys in the native table must stay put during compaction. */
    rb_gc_mark((VALUE)key);
    return ST_CONTINUE;
}

static void mark_tracker(void *data)
{
    struct tracker *tracker = data;
    if (tracker->classes) st_foreach(tracker->classes, mark_class, 0);
}

static void free_tracker(void *data)
{
    struct tracker *tracker = data;
    if (tracker->classes) st_free_table(tracker->classes);
    xfree(tracker);
}

static size_t tracker_size(const void *data)
{
    const struct tracker *tracker = data;
    return sizeof(*tracker) + (tracker->classes ? st_memsize(tracker->classes) : 0);
}

static const rb_data_type_t tracker_type = {
    .wrap_struct_name = "RailsTia::AllocatedClasses",
    .function = { .dmark = mark_tracker, .dfree = free_tracker, .dsize = tracker_size },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE allocate_tracker(VALUE klass)
{
    struct tracker *tracker;
    VALUE object = TypedData_Make_Struct(klass, struct tracker, &tracker_type, tracker);
    tracker->classes = st_init_numtable();
    return object;
}

static void record_allocation(VALUE self, const rb_trace_arg_t *event)
{
    VALUE object = rb_tracearg_object((rb_trace_arg_t *)event);
    if (!RB_TYPE_P(object, T_OBJECT) && !RB_TYPE_P(object, T_STRUCT)) return;

    /* NEWOBJ runs during allocation: defer Ruby calls and path lookup until flush. */
    VALUE klass = RBASIC_CLASS(object);
    if (!RTEST(klass)) return;
    struct tracker *tracker = RTYPEDDATA_DATA(self);
    if (klass == tracker->last_class) return;
    st_insert(tracker->classes, klass, 1);
    tracker->last_class = klass;
}

static VALUE start(VALUE self)
{
    struct tracker *tracker = RTYPEDDATA_DATA(self);
    if (!tracker->enabled) {
        rb_add_event_hook2((rb_event_hook_func_t)record_allocation,
                           RUBY_INTERNAL_EVENT_NEWOBJ, self,
                           RUBY_EVENT_HOOK_FLAG_SAFE | RUBY_EVENT_HOOK_FLAG_RAW_ARG);
        tracker->enabled = 1;
    }
    return self;
}

static VALUE stop(VALUE self)
{
    struct tracker *tracker = RTYPEDDATA_DATA(self);
    if (tracker->enabled) {
        rb_remove_event_hook_with_data((rb_event_hook_func_t)record_allocation, self);
        tracker->enabled = 0;
    }
    return self;
}

static int append_class(st_data_t key, st_data_t value, st_data_t array)
{
    rb_ary_push((VALUE)array, (VALUE)key);
    return ST_CONTINUE;
}

static VALUE drain(VALUE self)
{
    struct tracker *tracker = RTYPEDDATA_DATA(self);
    VALUE classes = rb_ary_new_capa(tracker->classes->num_entries);
    st_foreach(tracker->classes, append_class, classes);
    tracker->last_class = Qnil;
    st_clear(tracker->classes);
    return classes;
}

void Init_allocated_classes(void)
{
    VALUE mod = rb_define_module("RailsTia");
    VALUE klass = rb_define_class_under(mod, "AllocatedClasses", rb_cObject);
    rb_define_alloc_func(klass, allocate_tracker);
    rb_define_method(klass, "start", start, 0);
    rb_define_method(klass, "stop", stop, 0);
    rb_define_method(klass, "drain", drain, 0);
}
