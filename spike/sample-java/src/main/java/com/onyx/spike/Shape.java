package com.onyx.spike;

/** Interface with several implementors — the target for "show implementors". */
public interface Shape {
    /** Overridden across the hierarchy — the target for "show overrides". */
    double area();

    default String describe() {
        return getClass().getSimpleName() + " area=" + area();
    }
}
