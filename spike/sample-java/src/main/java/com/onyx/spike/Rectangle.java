package com.onyx.spike;

/** Direct implementor of Shape (not via AbstractShape) — proves the query
    distinguishes "implements interface" from "extends base class". */
public class Rectangle implements Shape {
    private final double width;
    private final double height;

    public Rectangle(double width, double height) {
        this.width = width;
        this.height = height;
    }

    @Override
    public double area() {
        return width * height;
    }
}
