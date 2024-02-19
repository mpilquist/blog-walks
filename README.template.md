# Optimizing Functional Walks of File Trees

The [fs2-io](https://fs2.io/#/io) library provides support for working with files in a functional way. It provides a single API that works on the JVM, Scala.js, and Scala Native.

As a first exapmle, consider counting the number of lines in a text file:

```scala mdoc
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

```scala mdoc
def countFiles(dir: Path): IO[Long] =
  Files[IO].walk(dir).compile.count
```

...or get the cumulative size of all files:

```scala mdoc
def totalSize(dir: Path): IO[Long] =
  Files[IO].walk(dir)
    .evalMap(p => Files[IO].getBasicFileAttributes(p))
    .map(_.size)
    .compile.foldMonoid
```

...or count the number of lines of code:

```scala mdoc
def scalaLinesIn(dir: Path): IO[Long] =
  Files[IO].walk(dir)
    .filter(_.extName == ".scala")
    .evalMap(lineCount)
    .compile.foldMonoid
```

The `walk` function supports a lot of additional functionality like limiting the depth of the traversal and following symbolic links. Let's reimplement 

```scala mdoc
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

```scala mdoc
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
```

And then let's walk it, counting the members and measuring how long it takes.

```scala mdoc
import scala.concurrent.duration.*

def time[A](f: => A): (FiniteDuration, A) =
  val start = System.currentTimeMillis
  val result = f
  val elapsed = (System.currentTimeMillis - start).millis
  (elapsed, result)

println(time(Files[IO].walk(largeDir).compile.count.unsafeRunSync()))
```

Ouch! Let's compare this to using Java's built in `java.nio.file.Files.walk`:

```scala mdoc
println(time(java.nio.file.Files.walk(largeDir.toNioPath).count()))
```

About five times slower! What can we do to improve this? Let's take a look at some options.

## Optimization 1: Using j.n.f.Files.walk

The Java file API provides a built-in `walk` operation that returns a Java `Stream`. Let's try wrapping that API directly:

```scala mdoc
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
```scala mdoc
println(time(jwalk[IO](largeDir, 1).compile.count.unsafeRunSync()))

println(time(jwalk[IO](largeDir, 1024).compile.count.unsafeRunSync()))
```

Even with a chunk size of 1, this implementation is nearly twice as fast as the original implementation. With a large chunk size, this implementation approaches the performance of using `JFiles.walk` directly.

Problem solved? Not quite. Unfortunately, `JFiles.walk` has a major limitation - [it provides no mechanism to handle exceptions while iterating](https://bugs.openjdk.org/browse/JDK-8039910). [Common wisdom](https://stackoverflow.com/questions/22867286/files-walk-calculate-total-size) is to use `JFiles.walkFileTree` instead. 

## Optimization 2: Using j.n.f.Files.walkFileTree

The `walkFileTree` function inverts control of the iteration -- it takes a `FileVisitor[Path]`, which provides callbacks like `visitFile` and `preVisitDirectory`. The simplest possible implementation is passing a `FileVisitor` that enqueues each visited file and directory in to a collection and upon termination, emits all collected entries as a single chunk.


```scala mdoc
import fs2.Chunk

def walkEager[F[_]: Sync](start: Path): Stream[F, Path] =
  import java.io.IOException
  import java.nio.file.{Files as JFiles, FileVisitor, FileVisitResult, Path as JPath}
  import java.nio.file.attribute.{BasicFileAttributes as JBasicFileAttributes}

  val doWalk = Sync[F].interruptible:
    val bldr = Vector.newBuilder[Path]
    JFiles.walkFileTree(
      start.toNioPath,
      new FileVisitor[JPath]:
        private def enqueue(path: JPath, attrs: JBasicFileAttributes): FileVisitResult =
          bldr += Path.fromNioPath(path)
          FileVisitResult.CONTINUE

        override def visitFile(file: JPath, attrs: JBasicFileAttributes): FileVisitResult =
          if Thread.interrupted() then FileVisitResult.TERMINATE else enqueue(file, attrs)

        override def visitFileFailed(file: JPath, t: IOException): FileVisitResult =
          FileVisitResult.CONTINUE

        override def preVisitDirectory(dir: JPath, attrs: JBasicFileAttributes): FileVisitResult =
          if Thread.interrupted() then FileVisitResult.TERMINATE else enqueue(dir, attrs)

        override def postVisitDirectory(dir: JPath, t: IOException): FileVisitResult =
          if Thread.interrupted() then FileVisitResult.TERMINATE else FileVisitResult.CONTINUE
    )

    Chunk.from(bldr.result())

  Stream.eval(doWalk).flatMap(Stream.chunk)
```

The implementation wraps the call to `walkFileTree` with `Sync[F].interruptible`, allowing cancellation of the fiber that executes the walk. The `FileVisitor` simply enqueus files and directories while checking the `Thread.interrupted()` flag.

This performs fairly well:

```scala mdoc
println(time(walkEager[IO](largeDir).compile.count.unsafeRunSync()))
```

Despite the performance, this implementation isn't sufficient for general use. We'd like an implementation that balances performance with lazy evaluation -- performing some file system operations and then yielding control to down-stream processing, instead of performing all file system operations upfront, before emitting anything.

## Optimization 3: Using j.n.f.Files.walkFileTree lazily

The `walkFileTree` operation doesn't allow us to suspend the traversal after we've accumulated some results. The best we can do is to block on enqueuing until our down-stream processing is ready for more elements. We can implement this by introducing concurrency. The general idea is to create a `fs2.concurrent.Channel` and return a `Stream[F, Path]` based on the elements sent to that channel. While down-stream pulls on that stream, concurrently evaluate the walk sending a chunk of paths to the channel as they are accumulated.

```scala mdoc
import cats.effect.Async

def walkLazy[F[_]: Async](start: Path, chunkSize: Int): Stream[F, Path] =
  import java.io.IOException
  import java.nio.file.{Files as JFiles, FileVisitor, FileVisitResult, Path as JPath}
  import java.nio.file.attribute.{BasicFileAttributes as JBasicFileAttributes}

  import cats.effect.std.Dispatcher
  import fs2.concurrent.Channel

  def doWalk(dispatcher: Dispatcher[F], channel: Channel[F, Chunk[Path]]) = Sync[F].interruptible:
    val bldr = Vector.newBuilder[Path]
    var size = 0
    JFiles.walkFileTree(
      start.toNioPath,
      new FileVisitor[JPath]:
        private def enqueue(path: JPath, attrs: JBasicFileAttributes): FileVisitResult =
          bldr += Path.fromNioPath(path)
          size += 1
          if size >= chunkSize then
            val result = dispatcher.unsafeRunSync(channel.send(Chunk.from(bldr.result())))
            bldr.clear()
            size = 0
            if result.isLeft then FileVisitResult.TERMINATE else FileVisitResult.CONTINUE
          else FileVisitResult.CONTINUE

        override def visitFile(file: JPath, attrs: JBasicFileAttributes): FileVisitResult =
          if Thread.interrupted() then FileVisitResult.TERMINATE else enqueue(file, attrs)

        override def visitFileFailed(file: JPath, t: IOException): FileVisitResult =
          FileVisitResult.CONTINUE

        override def preVisitDirectory(dir: JPath, attrs: JBasicFileAttributes): FileVisitResult =
          if Thread.interrupted() then FileVisitResult.TERMINATE else enqueue(dir, attrs)

        override def postVisitDirectory(dir: JPath, t: IOException): FileVisitResult =
          if Thread.interrupted() then FileVisitResult.TERMINATE else FileVisitResult.CONTINUE
    )
    dispatcher.unsafeRunSync(channel.closeWithElement(Chunk.from(bldr.result())))

  Stream.resource(Dispatcher.sequential[F]).flatMap:
    dispatcher =>
      Stream.eval(Channel.synchronous[F, Chunk[Path]]).flatMap:
        channel =>
          channel.stream.flatMap(Stream.chunk).concurrently(Stream.eval(doWalk(dispatcher, channel)))
```

The `enqueue` method handles sending an accumulated chunk to the channel upon reaching the desired chunk size. The `channel.send` operation returns an `IO[Either[Channel.Closed, Unit]]`. We need to run that value from within the visitor callback to ensure we backpressure the walk. We do that by using a `cats.effect.std.Dispatcher` and calling `unsafeRunSync`.

When the traversal completes, we might have some enqueued paths that need to be sent to the channel. We send a final chunk to the channel and close it via `channel.closeWithElement`.

The main body of `walkLazy` allocates a dispatcher and channel and then returns a stream from the channel while concurrently evaluating the walk.

Let's check performance:

```scala mdoc
println(time(walkLazy[IO](largeDir, 1024).compile.count.unsafeRunSync()))
```

## Optimization 4: Custom traversal

```scala mdoc
def walkJustInTime[F[_]: Sync](start: Path, chunkSize: Int): Stream[F, Path] =
  import scala.collection.immutable.Queue
  import scala.util.control.NonFatal
  import scala.util.Using
  import java.nio.file.{Files as JFiles, LinkOption}
  import java.nio.file.attribute.{BasicFileAttributes as JBasicFileAttributes}

  case class WalkEntry(
      path: Path,
      attr: JBasicFileAttributes
  )

  def loop(toWalk0: Queue[WalkEntry]): Stream[F, Path] =
    val partialWalk = Sync[F].interruptible:
      var acc = Vector.empty[Path]
      var toWalk = toWalk0

      while acc.size < chunkSize && toWalk.nonEmpty && !Thread.interrupted() do
        val entry = toWalk.head
        toWalk = toWalk.drop(1)
        acc = acc :+ entry.path
        if entry.attr.isDirectory then
          Using(JFiles.list(entry.path.toNioPath)):
            listing =>
              val descendants = listing.iterator.asScala.flatMap:
                p =>
                  try
                    val attr =
                      JFiles.readAttributes(
                        p,
                        classOf[JBasicFileAttributes],
                        LinkOption.NOFOLLOW_LINKS
                      )
                    Some(WalkEntry(Path.fromNioPath(p), attr))
                  catch case NonFatal(_) => None
              toWalk = Queue.empty ++ descendants ++ toWalk

      Stream.chunk(Chunk.from(acc)) ++ (if toWalk.isEmpty then Stream.empty else loop(toWalk))

    Stream.eval(partialWalk).flatten

  Stream
    .eval(Sync[F].interruptible:
      WalkEntry(
        start,
        JFiles.readAttributes(start.toNioPath, classOf[JBasicFileAttributes])
      )
    )
    .mask
    .flatMap(w => loop(Queue(w)))
```

```scala mdoc
println(time(walkJustInTime[IO](largeDir, 1024).compile.count.unsafeRunSync()))
```


## Conclusion

