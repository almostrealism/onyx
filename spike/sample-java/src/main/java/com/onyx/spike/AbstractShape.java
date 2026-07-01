package com.onyx.spike;

/** Abstract base — the target for "show subclasses" (Circle, Square). */
public abstract class AbstractShape implements Shape {
    protected final String name;

    protected AbstractShape(String name) {
        this.name = name;
    }

    public String name() {
        return name;
    }
}
