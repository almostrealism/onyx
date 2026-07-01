package com.onyx.spike;

import java.util.List;

/** Uses area() from several call sites — the target for "find references". */
public class Main {
    public static void main(String[] args) {
        List<Shape> shapes = List.of(
            new Circle(2.0),
            new Square(3.0),
            new Rectangle(2.0, 5.0));

        double total = 0;
        for (Shape s : shapes) {
            total += s.area();
            System.out.println(s.describe());
        }
        System.out.println("total area = " + total);
    }
}
