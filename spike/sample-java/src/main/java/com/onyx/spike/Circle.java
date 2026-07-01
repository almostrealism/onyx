package com.onyx.spike;

/** Subclass of AbstractShape; overrides area(). */
public class Circle extends AbstractShape {
    private final double radius;

    public Circle(double radius) {
        super("circle");
        this.radius = radius;
    }

    @Override
    public double area() {
        return Math.PI * radius * radius;
    }
}
