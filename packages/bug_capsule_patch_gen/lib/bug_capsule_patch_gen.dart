/// Lowers `@Patchable` functions without resolving types, using only the
/// published analyzer parser. Anything outside the subset is refused with a
/// location: a change the tool can't express must never silently do nothing.
library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

final class Unsupported implements Exception {
  Unsupported(this.reason, this.line);
  final String reason;
  final int line;

  @override
  String toString() => 'line $line: $reason';
}

final class PatchableFunction {
  PatchableFunction({required this.id, required this.name, required this.params, required this.returnType, required this.decl});

  final String id;

  /// The public name: `_$points` is implemented as `points`.
  final String name;
  final List<({String name, String type})> params;
  final String returnType;
  final FunctionDeclaration decl;
}

const _types = {'int': 'int', 'bool': 'bool', 'String': 'string'};
const _schema = {'int': 'int', 'bool': 'bool', 'String': 'str'};
const _ops = {'+', '-', '*', '==', '!=', '<', '<=', '>', '>=', '&&', '||'};

final class Unit {
  Unit(String source) : _result = parseString(content: source, throwIfDiagnostics: true) {
    for (final d in _result.unit.declarations.whereType<FunctionDeclaration>()) {
      final id = _patchableId(d);
      if (id == null) {
        _helpers[d.name.lexeme] = d;
      } else {
        patchables.add(_describe(d, id));
      }
    }
  }

  final ParseStringResult _result;
  final _helpers = <String, FunctionDeclaration>{};
  final patchables = <PatchableFunction>[];

  LineInfo get _lines => _result.lineInfo;
  int _line(AstNode n) => _lines.getLocation(n.offset).lineNumber;
  Never _no(AstNode n, String why) => throw Unsupported('$why: `${n.toSource()}`', _line(n));

  String? _patchableId(FunctionDeclaration d) {
    for (final m in d.metadata) {
      if (m.name.name != 'Patchable') continue;
      final a = m.arguments?.arguments;
      if (a == null || a.length != 1 || a.first is! SimpleStringLiteral) _no(m, 'Patchable takes one string literal');
      return (a.first as SimpleStringLiteral).value;
    }
    return null;
  }

  String _type(TypeAnnotation? t, AstNode at) {
    final s = t?.toSource();
    if (!_types.containsKey(s)) _no(at, 'only int, bool and String cross a patch boundary');
    return s!;
  }

  ({String name, String type}) _param(FormalParameter p) {
    if (p is! SimpleFormalParameter || !p.isRequiredPositional) _no(p, 'only required positional parameters are supported');
    return (name: p.name!.lexeme, type: _type(p.type, p));
  }

  PatchableFunction _describe(FunctionDeclaration d, String id) {
    final raw = d.name.lexeme;
    if (!raw.startsWith(r'_$')) _no(d, r'name a patchable function _$name');
    final expr = d.functionExpression;
    if (expr.body.isAsynchronous || expr.body.isGenerator) _no(d, 'async and generator functions are not supported');
    if (expr.typeParameters != null) _no(d, 'generics are not supported');
    return PatchableFunction(
      id: id,
      name: raw.substring(2),
      params: [for (final p in expr.parameters!.parameters) _param(p)],
      returnType: _type(d.returnType, d),
      decl: d,
    );
  }

  /// The module source for [f], with its helpers.
  String lower(PatchableFunction f) {
    final helpers = <String>{};
    final body = _body(f.decl, helpers);
    final out = StringBuffer('module ${f.id};\n\n');
    final done = <String>{};
    void emit(String name) {
      if (!done.add(name)) return;
      final h = _helpers[name]!;
      final used = <String>{};
      final text = _body(h, used);
      used.forEach(emit);
      final ps = [for (final p in h.functionExpression.parameters!.parameters) _param(p)];
      out.writeln('function $name(${ps.map((p) => '${p.name}: ${_types[p.type]}').join(', ')}): ${_types[_type(h.returnType, h)]} {\n$text}\n');
    }

    helpers.forEach(emit);
    final fields = [...f.params]..sort((a, b) => a.name.compareTo(b.name));
    out.writeln('type Input = { ${fields.map((p) => '${p.name}: ${_types[p.type]}').join(', ')} };\n');
    out.writeln('export function compute(input__: Input): ${_types[f.returnType]} {');
    for (final p in f.params) {
      out.writeln('  const ${p.name} = input__.${p.name};');
    }
    out.write('$body}\n');
    return out.toString();
  }

  String _body(FunctionDeclaration d, Set<String> helpers) {
    final body = d.functionExpression.body;
    if (body is ExpressionFunctionBody) return '  return ${_expr(body.expression, helpers)};\n';
    if (body is BlockFunctionBody) return _block(body.block, helpers);
    _no(d, 'external functions are not supported');
  }

  String _block(Block b, Set<String> helpers) => b.statements.map((s) => _stmt(s, helpers)).join();

  String _stmt(Statement s, Set<String> h) {
    switch (s) {
      case ReturnStatement(:final expression?):
        return '  return ${_expr(expression, h)};\n';
      case VariableDeclarationStatement(:final variables):
        if (variables.variables.length != 1) _no(s, 'declare one variable per statement');
        final v = variables.variables.single;
        if (v.initializer == null) _no(s, 'variables need an initializer');
        final kw = variables.isFinal || variables.isConst ? 'const' : 'let';
        return '  $kw ${v.name.lexeme} = ${_expr(v.initializer!, h)};\n';
      case IfStatement(:final expression, :final thenStatement, :final elseStatement, caseClause: null):
        final t = thenStatement is Block ? _block(thenStatement, h) : _stmt(thenStatement, h);
        final e = elseStatement == null ? '' : ' else {\n${elseStatement is Block ? _block(elseStatement, h) : _stmt(elseStatement, h)}  }';
        return '  if (${_expr(expression, h)}) {\n$t  }$e\n';
      case ExpressionStatement(expression: AssignmentExpression(:final leftHandSide, :final operator, :final rightHandSide))
          when leftHandSide is SimpleIdentifier && operator.type == TokenType.EQ:
        return '  ${leftHandSide.name} = ${_expr(rightHandSide, h)};\n';
      case Block():
        return _block(s, h);
      default:
        _no(s, 'statement outside the supported subset');
    }
  }

  String _expr(Expression e, Set<String> h) {
    switch (e) {
      case IntegerLiteral(:final value?):
        return '$value';
      case BooleanLiteral(:final value):
        return '$value';
      case SimpleStringLiteral(:final value):
        final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n').replaceAll('\t', r'\t').replaceAll('\r', r'\r');
        return '"$escaped"';
      case SimpleIdentifier(:final name):
        return name;
      case ParenthesizedExpression(:final expression):
        return '(${_expr(expression, h)})';
      case PrefixExpression(:final operator, :final operand) when operator.type == TokenType.MINUS || operator.type == TokenType.BANG:
        return '${operator.lexeme}${_expr(operand, h)}';
      case ConditionalExpression(:final condition, :final thenExpression, :final elseExpression):
        return '(${_expr(condition, h)} ? ${_expr(thenExpression, h)} : ${_expr(elseExpression, h)})';
      case BinaryExpression(:final leftOperand, :final operator, :final rightOperand):
        final op = operator.lexeme;
        // Dart `/` gives a double and `%` is Euclidean: neither is the IR's meaning.
        if (op == '~/') return '(${_expr(leftOperand, h)} / ${_expr(rightOperand, h)})';
        if (!_ops.contains(op)) _no(e, 'operator $op has no matching semantics');
        return '(${_expr(leftOperand, h)} $op ${_expr(rightOperand, h)})';
      case MethodInvocation(target: null, :final methodName, :final argumentList):
        if (!_helpers.containsKey(methodName.name)) _no(e, 'only pure top-level functions in this file can be called');
        h.add(methodName.name);
        return '${methodName.name}(${argumentList.arguments.map((a) => _expr(a, h)).join(', ')})';
      default:
        _no(e, 'expression outside the supported subset');
    }
  }

  /// The `part` file: one dispatching stub per patchable function.
  String stubs(String partOf) {
    final out = StringBuffer("// GENERATED by bcpatch_gen. Do not edit.\npart of '$partOf';\n\n");
    out.writeln('final patchableModules = <PatchModule<dynamic, dynamic>>[');
    for (final f in patchables) {
      out.writeln('  _\$${f.name}Module,');
    }
    out.writeln('];\n');
    for (final f in patchables) {
      final fields = [...f.params]..sort((a, b) => a.name.compareTo(b.name));
      final schema = 'rec(${fields.map((p) => '${p.name}:${_schema[p.type]}').join(',')})';
      final args = f.params.map((p) => p.name).join(', ');
      final map = f.params.map((p) => "'${p.name}': ${p.name}").join(', ');
      final positional = f.params.map((p) => "input['${p.name}'] as ${p.type}").join(', ');
      out.writeln('''
final _\$${f.name}Module = PatchModule<Map<String, Object?>, ${f.returnType}>(
  id: '${f.id}',
  inputSchema: '$schema',
  outputSchema: '${_schema[f.returnType]}',
  encode: (input) => input,
  decode: (output) => output! as ${f.returnType},
  fallback: (input) => _\$${f.name}($positional),
);

${f.returnType} ${f.name}(${f.params.map((p) => '${p.type} ${p.name}').join(', ')}) => PatchDispatch.call(_\$${f.name}Module, {$map});
''');
      if (args.isEmpty) _no(f.decl, 'a patchable function takes at least one parameter');
    }
    return out.toString();
  }
}
