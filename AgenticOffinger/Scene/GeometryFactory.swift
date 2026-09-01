import Foundation
import SceneKit
import simd

/// Turns BTLX polygon soup into SceneKit geometry.
///
/// Faces arrive as arbitrary planar index loops, so they are triangulated by ear
/// clipping in the face plane. Vertices are written out per triangle rather than
/// shared, which gives every face its own normal — the flat, hard-edged shading a
/// shop drawing needs, with no smoothing across the corners of a stud.
enum GeometryFactory {

    // MARK: - Solid

    static func solid(from mesh: Mesh) -> SCNGeometry? {
        guard !mesh.isEmpty else { return nil }

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        positions.reserveCapacity(mesh.faces.count * 6)
        normals.reserveCapacity(mesh.faces.count * 6)

        for face in mesh.faces {
            let loop = face.compactMap { $0 < mesh.points.count ? mesh.points[$0] : nil }
            guard loop.count >= 3 else { continue }
            let normal = newellNormal(loop)
            guard simd_length(normal) > 1e-12 else { continue }

            for triangle in triangulate(loop, normal: normal) {
                for point in triangle {
                    positions.append(SCNVector3(Float(point.x), Float(point.y), Float(point.z)))
                    normals.append(SCNVector3(Float(normal.x), Float(normal.y), Float(normal.z)))
                }
            }
        }
        guard !positions.isEmpty else { return nil }

        let indices = (0..<Int32(positions.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions),
                                     SCNGeometrySource(normals: normals)],
                           elements: [element])
    }

    // MARK: - Edges

    /// The face boundaries as a line set, drawn over the solid so parts read as
    /// discrete members instead of one shaded mass.
    static func edges(from mesh: Mesh) -> SCNGeometry? {
        guard !mesh.isEmpty else { return nil }

        var seen = Set<Int64>()
        var positions: [SCNVector3] = []
        var indices: [Int32] = []

        for face in mesh.faces {
            guard face.count >= 2 else { continue }
            for i in 0..<face.count {
                let a = face[i], b = face[(i + 1) % face.count]
                guard a < mesh.points.count, b < mesh.points.count, a != b else { continue }
                let key = Int64(Swift.min(a, b)) << 32 | Int64(Swift.max(a, b))
                guard seen.insert(key).inserted else { continue }
                for index in [a, b] {
                    let p = mesh.points[index]
                    indices.append(Int32(positions.count))
                    positions.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
                }
            }
        }
        guard !positions.isEmpty else { return nil }

        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions)], elements: [element])
    }

    // MARK: - Triangulation

    /// Newell's method: robust for any planar polygon, convex or not.
    private static func newellNormal(_ loop: [SIMD3<Double>]) -> SIMD3<Double> {
        var n = SIMD3<Double>.zero
        for i in 0..<loop.count {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        }
        let length = simd_length(n)
        return length > 0 ? n / length : n
    }

    private static func triangulate(_ loop: [SIMD3<Double>],
                                    normal: SIMD3<Double>) -> [[SIMD3<Double>]] {
        if loop.count == 3 { return [loop] }

        // Project onto the plane by dropping the axis the normal points most strongly along.
        let drop = dominantAxis(normal)
        let flip = normal[drop] < 0
        func flatten(_ p: SIMD3<Double>) -> SIMD2<Double> {
            switch drop {
            case 0:  return flip ? SIMD2(p.z, p.y) : SIMD2(p.y, p.z)
            case 1:  return flip ? SIMD2(p.x, p.z) : SIMD2(p.z, p.x)
            default: return flip ? SIMD2(p.y, p.x) : SIMD2(p.x, p.y)
            }
        }

        var remaining = Array(loop.indices)
        let flat = loop.map(flatten)
        var triangles: [[SIMD3<Double>]] = []
        var guardCounter = 0

        while remaining.count > 3 && guardCounter < loop.count * loop.count {
            guardCounter += 1
            var clipped = false
            for i in 0..<remaining.count {
                let prev = remaining[(i + remaining.count - 1) % remaining.count]
                let curr = remaining[i]
                let next = remaining[(i + 1) % remaining.count]
                guard isEar(prev, curr, next, in: remaining, flat: flat) else { continue }
                triangles.append([loop[prev], loop[curr], loop[next]])
                remaining.remove(at: i)
                clipped = true
                break
            }
            // Degenerate or self-intersecting outline: fall back to a fan so the face
            // is still drawn rather than silently dropped.
            if !clipped { break }
        }
        if remaining.count == 3 {
            triangles.append([loop[remaining[0]], loop[remaining[1]], loop[remaining[2]]])
        } else if remaining.count > 3 {
            for i in 1..<(remaining.count - 1) {
                triangles.append([loop[remaining[0]], loop[remaining[i]], loop[remaining[i + 1]]])
            }
        }
        return triangles
    }

    private static func isEar(_ a: Int, _ b: Int, _ c: Int,
                              in remaining: [Int], flat: [SIMD2<Double>]) -> Bool {
        let pa = flat[a], pb = flat[b], pc = flat[c]
        let area = cross(pb - pa, pc - pa)
        guard area > 1e-9 else { return false }          // reflex or collinear
        for index in remaining where index != a && index != b && index != c {
            if pointInTriangle(flat[index], pa, pb, pc) { return false }
        }
        return true
    }

    private static func cross(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double {
        u.x * v.y - u.y * v.x
    }

    private static func pointInTriangle(_ p: SIMD2<Double>,
                                        _ a: SIMD2<Double>,
                                        _ b: SIMD2<Double>,
                                        _ c: SIMD2<Double>) -> Bool {
        let d1 = cross(b - a, p - a)
        let d2 = cross(c - b, p - b)
        let d3 = cross(a - c, p - c)
        return d1 >= -1e-12 && d2 >= -1e-12 && d3 >= -1e-12
    }

    private static func dominantAxis(_ v: SIMD3<Double>) -> Int {
        let a = abs(v)
        if a.x >= a.y && a.x >= a.z { return 0 }
        return a.y >= a.z ? 1 : 2
    }
}
