//go:build darwin

package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"sort"
	"testing"
)

// render() reached for a menu item that buildMenu no longer created, and dereferenced
// nil every five seconds until the app died.
//
// Nothing caught it. It compiles cleanly, because the field still exists; it is simply
// never assigned. The type system cannot see the gap, and no unit test can call
// buildMenu because it needs a live systray.
//
// So read the source instead. Every menu field that render touches must be assigned in
// buildMenu. Deleting an item from the menu without deleting its use now fails here
// rather than on someone's machine.
func TestRenderOnlyTouchesItemsBuildMenuCreates(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "menu.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}

	assigned := map[string]bool{}
	used := map[string]bool{}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok {
			continue
		}

		switch fn.Name.Name {
		case "buildMenu":
			// m.<field> = ...
			ast.Inspect(fn, func(n ast.Node) bool {
				as, ok := n.(*ast.AssignStmt)
				if !ok {
					return true
				}
				for _, lhs := range as.Lhs {
					if name, ok := receiverField(lhs, "m"); ok {
						assigned[name] = true
					}
				}
				return true
			})

		case "render":
			// m.<field>.Something()
			ast.Inspect(fn, func(n ast.Node) bool {
				sel, ok := n.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				if name, ok := receiverField(sel.X, "m"); ok {
					used[name] = true
				}
				return true
			})
		}
	}

	if len(assigned) == 0 || len(used) == 0 {
		t.Fatalf("parsed nothing useful: %d assigned, %d used", len(assigned), len(used))
	}

	var missing []string
	for name := range used {
		if !assigned[name] {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)

	if len(missing) > 0 {
		t.Fatalf("render uses menu fields that buildMenu never assigns, so they are nil "+
			"at runtime: %v", missing)
	}
}

// receiverField reports the field name in an expression like `m.status`.
func receiverField(e ast.Expr, receiver string) (string, bool) {
	sel, ok := e.(*ast.SelectorExpr)
	if !ok {
		return "", false
	}
	ident, ok := sel.X.(*ast.Ident)
	if !ok || ident.Name != receiver {
		return "", false
	}
	return sel.Sel.Name, true
}
