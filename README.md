# Optimizing Functional Walks of File Trees

The [fs2-io](https://fs2.io/#/io) library provides support for working with files in a functional way. It provides a single API that works on the JVM, Scala.js, and Scala Native.

As a first exapmle, consider counting the number of lines in a text file:

```scala
import fs2.io.file.{Files, Path}
import cats.effect.IO

def lineCount(p: Path): IO[Long] =
	Files[IO].readUtf8Lines(p).mask.compile.count
```

The `lineCount` function uses takes the path of a file to read and returns the number of lines in that file. It uses the `readUtf8Lines` function from `Files[IO]`, which returns a `Stream[IO, String]`. Each value emitted from that stream is a separate line from the source file. The `mask` operation ignores any errors and `compile.count` converts the streaming computation to a single value by counting the number of output elements.

The fs2 library promotes compositional program design, and its APIs are built on that principle. For example, the `readUtf8Lines` function is an alias for the composition of some lower level functions. Taking a look at the `Files` interface, we find that `readUtf8Lines` composes `readUtf8` and `text.lines`. Going another level deeper shows `readUtf8` composes `readAll` and `text.utf8.decode`.

```scala
trait Files[F[_]]:

  /** Reads all bytes from the file specified and decodes them as utf8 lines. */
  def readUtf8Lines(path: Path): Stream[F, String] = readUtf8(path).through(text.lines)

  /** Reads all bytes from the file specified and decodes them as a utf8 string. */
  def readUtf8(path: Path): Stream[F, String] = readAll(path).through(text.utf8.decode)


  /** Reads all bytes from the file specified. */
  def readAll(path: Path): Stream[F, Byte] = readAll(path, 64 * 1024, Flags.Read)

  /** Reads all bytes from the file specified, reading in chunks up to the specified limit,
    * and using the supplied flags to open the file.
    */
  def readAll(path: Path, chunkSize: Int, flags: Flags): Stream[F, Byte]
```

The `Files` interface has both high level operations like `readUtf8Lines` and low level operations like `readAll`. In this article, we'll look at the high level `walk` operation and incrementally refactor it to improve performance.

## Walks

The `walk` operation provides a `Stream[IO, Path]` that contains an entry for each file and directory in the specified tree. We can combine `walk` with other operations. For instance, we can count the number of files in a tree:

```scala
def countFiles(dir: Path): IO[Long] =
  Files[IO].walk(dir).compile.count
```

...or get the cumulative size of all files:

```scala
def totalSize(dir: Path): IO[Long] =
  Files[IO].walk(dir)
    .evalMap(p => Files[IO].getBasicFileAttributes(p))
    .map(_.size)
    .compile.foldMonoid
```

...or count the number of lines of code:

```scala
def scalaLinesIn(dir: Path): IO[Long] =
  Files[IO].walk(dir)
    .filter(_.extName == ".scala")
    .evalMap(lineCount)
    .compile.foldMonoid
```

The `walk` function supports a lot of additional functionality like limiting the depth of the traversal and following symbolic links. Let's reimplement 

```scala
import fs2.Stream

def walkSimple[F[_]: Files](start: Path): Stream[F, Path] =
  Stream.eval(Files[F].getBasicFileAttributes(start)).mask.flatMap: attr =>
    val next =
      if attr.isDirectory then
        Files[F].list(start).mask.flatMap(walkSimple)
      else Stream.empty
    Stream.emit(start) ++ next
```

This implementation uses two lower level operations from `Files` -- `getBasicFileAttributes` and `list`. The `getBasicFileAttributes` operation is used to determine if the current path is a directory, and if so, the `list` operation is used to get the direct descendants of the directory and we recursively walk each descendant. Stack safety and early termination are both provided by `Stream`. The `mask` operation is used after both file system operations to turn errors in to empty streams, resulting in a lenient walk -- for example, if we don't have permissions to read a file or a file is deleted while we're traversing, we just continue walking.

## Performance

Unfortunately, the simple implementation doesn't perform that well. To observe the issue, let's create a large directory tree.

```scala
import cats.syntax.all.*

def makeLargeDir: IO[Path] =
  Files[IO].createTempDirectory.flatMap:
    dir =>
      val MaxDepth = 7
      val Names = 'A'.to('E').toList.map(_.toString)

      def loop(cwd: Path, depth: Int): IO[Unit] =
        if depth < MaxDepth then
          Names.traverse_ :
            name =>
              val p = cwd / name
              Files[IO].createDirectory(p) >>
                loop(p, depth + 1)
        else if (depth == MaxDepth)
          Names.traverse_ :
            name =>
              Files[IO].createFile(cwd / name)
        else IO.unit

      loop(dir, 0).as(dir)

import cats.effect.unsafe.implicits.global
val largeDir = makeLargeDir.unsafeRunSync() 
// largeDir: Path = /var/folders/q4/tm2l78qj6zq0x4_7hrlpckcm0000gn/T/17960056301335785752
```

And then let's walk it, counting the members and measuring how long it takes.

```scala
import scala.concurrent.duration.*

def time[A](f: => A): (FiniteDuration, A) =
  val start = System.currentTimeMillis
  val result = f
  val elapsed = (System.currentTimeMillis - start).millis
  (elapsed, result)

println(time(Files[IO].walk(largeDir).compile.count.unsafeRunSync()))
// (26622 milliseconds,488281)
```

Ouch! Let's compare this to using Java's built in `java.nio.file.Files.walk`:

```scala
println(time(java.nio.file.Files.walk(largeDir.toNioPath).count()))
// (5679 milliseconds,488281)
```

About five times slower! What can we do to improve this? Let's take a look at some options.

## Optimization 1: Using j.n.f.Files.walk

The Java file API provides a built-in `walk` operation that returns a Java `Stream`. Let's try wrapping that API directly:

```scala
import cats.effect.{Resource, Sync}
import scala.jdk.CollectionConverters.*

def jwalk[F[_]: Sync](start: Path, chunkSize: Int): Stream[F, Path] =
  import java.nio.file.{Files as JFiles}
  def doWalk = Sync[F].blocking(JFiles.walk(start.toNioPath))
  Stream.resource(Resource.fromAutoCloseable(doWalk))
    .flatMap(jstr => Stream.fromBlockingIterator(jstr.iterator().asScala, chunkSize))
    .map(jpath => Path.fromNioPath(jpath))
```

This implementation converts the Java stream returned by `JFiles.walk` to an `fs2.Stream` by using `Stream.fromBlockingIterator`. The `fromBlockingIterator` operation calls `next()` on the provided iterator, accumulating up to the specified chunk limit before emitting a chunk of values. Here, we simply added a new `chunkSize` parameter to the `jwalk` signature so we can experiment with different chunk sizes. There's some additional machinery to ensure the walk is closed propertly (handled by `Resource.fromAutoCloseable`) and some conversions between Java and Scala types.

Let's see how this performs:
```scala
println(time(jwalk[IO](largeDir, 1).compile.count.unsafeRunSync()))
// (14776 milliseconds,488281)

println(time(jwalk[IO](largeDir, 1024).compile.count.unsafeRunSync()))
// (5916 milliseconds,488281)
```

Even with a chunk size of 1, this implementation is nearly twice as fast. With a large chunk size, this implementation approaches the performance of using `JFiles.walk` directly.

## Optimization 2: Using j.n.f.Files.walkFileTree 

## Optimization 3: Using j.n.f.Files.walkFileTree eagerly

## Optimization 4: Custom traversal

## Conclusion

