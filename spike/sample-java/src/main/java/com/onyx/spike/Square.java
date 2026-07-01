package com.onyx.spike;

/** Subclass of AbstractShape; overrides area(). */
public class Square extends AbstractShape {
    private final double side;

    public Square(double side) {
        super("square");
        this.side = side;
    }

    @Override
    public double area() {
        return side * side;
    }
}
