extends DotFpsHullBody


static func hull_at(feet: Vector3, height: float, radius: float) -> AABB:
	return AABB(feet - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, height, radius * 2.0))
